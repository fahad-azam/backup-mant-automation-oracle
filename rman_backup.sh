#!/bin/bash

#======================================================
# RMAN Backup Script (env from $HOME/.dbname + per-DB config)
# Usage:
#   ./rman_backup.sh <full|incr0|archivelog|arch|maint> <config_file> [mail_to_override]
#======================================================

set -u

#-------- Args --------
if [ $# -lt 3 ]; then
    echo "Usage: $0 <full|incr0|archivelog|arch|maint> <config_file> [mail_to_override]"
    exit 1
fi

DBNAME_RAW="$1"
BACKUP_TYPE_RAW="$2"
CONF_FILE="$3"
MAIL_OVERRIDE="${4:-}"

#-------- Normalize / Validate --------
DBNAME=$(echo "$DBNAME_RAW" | tr '[:upper:]' '[:lower:]')
BACKUP_TYPE=$(echo "$BACKUP_TYPE_RAW" | tr '[:upper:]' '[:lower:]')

# Accept 'arch' as shorthand
if [ "$BACKUP_TYPE" = "arch" ]; then BACKUP_TYPE="archivelog"; fi

case "$BACKUP_TYPE" in
    full|incr0|archivelog|maint) ;;
    *)
        echo "Error: invalid backup type '$BACKUP_TYPE_RAW'. Allowed: full | incr0 | archivelog | maint"
        exit 1
        ;; 
esac

#-------- Source Oracle environment from $HOME/. --------
ENV_FILE="$HOME/.${DBNAME}"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
else
    echo "Error: Oracle env file not found: $ENV_FILE"
    exit 1
fi

#-------- Load DB-specific config (passed as parameter) --------
if [ ! -f "$CONF_FILE" ]; then
    echo "Error: config file not found: $CONF_FILE"
    exit 1
fi
# shellcheck disable=SC1090
. "$CONF_FILE"

# Required from config: BACKUP_BASE, LOG_DIR
if [ -z "${BACKUP_BASE:-}" ] || [ -z "${LOG_DIR:-}" ]; then
    echo "Error: BACKUP_BASE and LOG_DIR must be defined in config."
    exit 1
fi

# Optional in config: MAIL_TO, CHANNELS (default to 2 if not specified)
MAIL_TO="${MAIL_OVERRIDE:-${MAIL_TO:-}}"

#-------- Determine channel count for each backup type --------
# Use type-specific channels if defined, otherwise fall back to CHANNELS, then default to 2
if [ "$BACKUP_TYPE" = "full" ] && [ -n "${CHANNELS_FULL:-}" ]; then
    CHANNELS="$CHANNELS_FULL"
    CHANNEL_SOURCE="config file (CHANNELS_FULL)"
elif [ "$BACKUP_TYPE" = "incr0" ] && [ -n "${CHANNELS_INCR0:-}" ]; then
    CHANNELS="$CHANNELS_INCR0"
    CHANNEL_SOURCE="config file (CHANNELS_INCR0)"
elif [ "$BACKUP_TYPE" = "archivelog" ] && [ -n "${CHANNELS_ARCH:-}" ]; then
    CHANNELS="$CHANNELS_ARCH"
    CHANNEL_SOURCE="config file (CHANNELS_ARCH)"
elif [ -n "${CHANNELS:-}" ]; then
    CHANNELS="$CHANNELS"
    CHANNEL_SOURCE="config file (CHANNELS)"
else
    CHANNELS=2
    CHANNEL_SOURCE="default"
fi

# For archivelog backups, always use at least 1 channel
if [ "$BACKUP_TYPE" = "archivelog" ] && [ "$CHANNELS" -lt 1 ]; then
    CHANNELS=1
fi

#-------- Lock file setup (now in main script) --------
LOCK_FILE="${LOG_DIR}/rman_${DBNAME}.lock"

# Ensure log directory exists
mkdir -p "$LOG_DIR" || { echo "Error: cannot create LOG_DIR: $LOG_DIR"; exit 1; }

#-------- Lock to prevent concurrent runs --------
if [ -f "$LOCK_FILE" ]; then
    echo "Another backup appears to be running for Lock: $LOCK_FILE"
    exit 1
fi
echo $$ > "$LOCK_FILE"
cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

#-------- Paths / Folders --------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# For maint mode, we don't need target directory
if [ "$BACKUP_TYPE" != "maint" ]; then
    # Per your required layout:
    # full: BACKUP_BASE//full/
    # incr0: BACKUP_BASE//incr0/
    # arch: BACKUP_BASE//full/arch/
    if [ "$BACKUP_TYPE" = "full" ]; then
        TARGET_DIR="${BACKUP_BASE}/${DBNAME}/full/${TIMESTAMP}" 
    elif [ "$BACKUP_TYPE" = "incr0" ]; then
        TARGET_DIR="${BACKUP_BASE}/${DBNAME}/incr0/${TIMESTAMP}" 
    else
        TARGET_DIR="${BACKUP_BASE}/${DBNAME}/full/arch/${TIMESTAMP}" 
    fi
    mkdir -p "$TARGET_DIR" || { echo "Error: cannot create TARGET_DIR: $TARGET_DIR"; exit 1; }
fi

LOGFILE="${LOG_DIR}/${DBNAME}${BACKUP_TYPE}${TIMESTAMP}.log"

#-------- Generate channel allocation commands --------
generate_channels() {
    local channels=$1
    local direction=$2 # "allocate" or "release"
    for ((i=1; i<=channels; i++)); do
        if [ "$direction" = "allocate" ]; then 
            echo "ALLOCATE CHANNEL c${i} DEVICE TYPE DISK;"
        else 
            echo "RELEASE CHANNEL c${i};"
        fi 
    done
}

#-------- Mail helper --------
send_failure_mail() {
    if [ -n "$MAIL_TO" ]; then
        SUBJECT="RMAN BACKUP FAILED: ${DBNAME} (${BACKUP_TYPE}) @ ${TIMESTAMP}"
        mail -s "$SUBJECT" "$MAIL_TO" < "$LOGFILE" 
    fi
}

#-------- Run RMAN --------
echo "[$(date +'%F %T')] Starting $BACKUP_TYPE backup for $DBNAME using $CHANNELS channels (from $CHANNEL_SOURCE)" | tee -a "$LOGFILE"

if [ "$BACKUP_TYPE" = "full" ]; then
    rman target / log="$LOGFILE" <<EOF
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${TARGET_DIR}/cf_%F';
RUN {
$(generate_channels "$CHANNELS" "allocate")
BACKUP AS COMPRESSED BACKUPSET DATABASE FORMAT '${TARGET_DIR}/full_%U.bkp';
BACKUP AS COMPRESSED BACKUPSET ARCHIVELOG ALL FORMAT '${TARGET_DIR}/arch_%U.bkp' DELETE INPUT;
$(generate_channels "$CHANNELS" "release")
}
EOF

elif [ "$BACKUP_TYPE" = "incr0" ]; then
    rman target / log="$LOGFILE" <<EOF
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${TARGET_DIR}/cf_%F';
RUN {
$(generate_channels "$CHANNELS" "allocate")
BACKUP INCREMENTAL LEVEL 0 AS COMPRESSED BACKUPSET DATABASE FORMAT '${TARGET_DIR}/incr0_%U.bkp';
BACKUP AS COMPRESSED BACKUPSET ARCHIVELOG ALL FORMAT '${TARGET_DIR}/arch_%U.bkp' DELETE INPUT;
$(generate_channels "$CHANNELS" "release")
}
EOF

elif [ "$BACKUP_TYPE" = "archivelog" ]; then
    rman target / log="$LOGFILE" <<EOF
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${TARGET_DIR}/cf_%F';
RUN {
$(generate_channels "$CHANNELS" "allocate")
BACKUP AS COMPRESSED BACKUPSET ARCHIVELOG ALL FORMAT '${TARGET_DIR}/arch_%U.bkp' DELETE INPUT;
$(generate_channels "$CHANNELS" "release")
}
EOF

else
    # Maintenance mode - only cleanup operations
    rman target / log="$LOGFILE" <<EOF
CROSSCHECK BACKUP;
CROSSCHECK ARCHIVELOG ALL;
CROSSCHECK COPY;
DELETE NOPROMPT OBSOLETE RECOVERY WINDOW OF 15 DAYS;
DELETE NOPROMPT EXPIRED BACKUP;
DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;
#DELETE NOPROMPT FAILED BACKUP
EOF
fi

STATUS=$?

#-------- Result handling --------
if [ $STATUS -ne 0 ]; then
    echo "[$(date +'%F %T')] Backup FAILED for ${DBNAME} (${BACKUP_TYPE}). Log: $LOGFILE" | tee -a "$LOGFILE"
    send_failure_mail
    exit 1
fi

echo "[$(date +'%F %T')] Backup SUCCESS for ${DBNAME} (${BACKUP_TYPE})" | tee -a "$LOGFILE"

#-------- Always run cleanup after successful backup (except in maint mode) --------
if [ "$BACKUP_TYPE" != "maint" ]; then
    echo "[$(date +'%F %T')] Cleaning up RMAN backups older than 15 days..." | tee -a "$LOGFILE"
    rman target / log="$LOGFILE" <<EOF
CROSSCHECK BACKUP;
CROSSCHECK ARCHIVELOG ALL;
DELETE NOPROMPT OBSOLETE RECOVERY WINDOW OF 15 DAYS;
DELETE EXPIRED BACKUP;
DELETE EXPIRED ARCHIVELOG ALL;
EOF
    CLEANUP_STATUS=$?
    if [ $CLEANUP_STATUS -ne 0 ]; then
        echo "[$(date +'%F %T')] Cleanup completed with warnings for ${DBNAME}" | tee -a "$LOGFILE" 
    else
        echo "[$(date +'%F %T')] Cleanup SUCCESS for ${DBNAME}" | tee -a "$LOGFILE" 
    fi
fi

exit 0
