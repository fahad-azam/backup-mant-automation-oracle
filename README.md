# backup-mant-automation-oracle
script to automate backup to an nfs 
Here's a comprehensive README.md file for your RMAN backup script:

```markdown
# RMAN Backup Script

A flexible, production-ready RMAN backup script for Oracle databases with support for multiple backup types, channel management, and automatic cleanup.

## Features

- **Multiple Backup Types**: Full, Incremental Level 0, Archive Log, and Maintenance modes
- **Channel Management**: Configurable parallel channels per backup type
- **Organized Directory Structure**: Timestamp-based backup directories
- **Control File Auto-backup**: Automatically places control files in the correct backup directory
- **Lock File Protection**: Prevents concurrent backup runs
- **Email Notifications**: Configurable failure alerts
- **Automatic Cleanup**: Removes obsolete backups (15-day retention)
- **Per-Database Configuration**: Separate config files for each database
- **Flexible Channel Configuration**: Support for different channel counts per backup type

## Prerequisites

- Oracle Database (10g or later)
- RMAN installed and configured
- Appropriate filesystem permissions for backup directories
- `mail` command configured for email notifications (optional)

## Installation

1. **Download the script**:
   ```bash
   curl -O https://your-repo/rman_backup.sh
   chmod +x rman_backup.sh
   ```

2. **Create Oracle environment file** for each database:
   ```bash
   vi $HOME/.orcl
   ```
   ```bash
   export ORACLE_SID=orcl
   export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
   export PATH=$ORACLE_HOME/bin:$PATH
   export LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH
   ```

3. **Create configuration file** for each database:
   ```bash
   vi /path/to/orcl_backup.conf
   ```

## Configuration File Structure

### Required Parameters
```bash
# Base directory for backups
BACKUP_BASE="/u01/backup"

# Directory for backup logs
LOG_DIR="/u01/logs/rman"
```

### Optional Parameters
```bash
# Email recipient for failure notifications
MAIL_TO="dba@example.com"

# Default number of RMAN channels (default: 2)
CHANNELS=2

# Type-specific channels (override CHANNELS)
CHANNELS_FULL=4      # Channels for full backups
CHANNELS_INCR0=4     # Channels for incremental level 0
CHANNELS_ARCH=2      # Channels for archive log backups
```

### Example Configuration File
```bash
# /path/to/orcl_backup.conf
BACKUP_BASE="/u01/backup/oracle"
LOG_DIR="/u01/logs/rman/orcl"
MAIL_TO="dba@example.com"
CHANNELS_FULL=4
CHANNELS_INCR0=4
CHANNELS_ARCH=2
```

## Usage

### Command Syntax
```bash
./rman_backup.sh <backup_type> <config_file> [mail_to_override]
```

### Backup Types

| Type | Description | Directory Structure |
|------|-------------|---------------------|
| `full` | Full database backup + archive logs | `${BACKUP_BASE}/${DBNAME}/full/YYYYMMDD_HHMMSS/` |
| `incr0` | Incremental level 0 backup + archive logs | `${BACKUP_BASE}/${DBNAME}/incr0/YYYYMMDD_HHMMSS/` |
| `archivelog` | Archive logs only | `${BACKUP_BASE}/${DBNAME}/full/arch/YYYYMMDD_HHMMSS/` |
| `maint` | Maintenance only (cleanup, no backup) | N/A |

### Examples

```bash
# Full backup
./rman_backup.sh full /etc/oracle/orcl_backup.conf

# Incremental level 0 backup
./rman_backup.sh incr0 /etc/oracle/orcl_backup.conf

# Archive log backup
./rman_backup.sh archivelog /etc/oracle/orcl_backup.conf

# Archive log backup (using shorthand)
./rman_backup.sh arch /etc/oracle/orcl_backup.conf

# Maintenance mode (cleanup only)
./rman_backup.sh maint /etc/oracle/orcl_backup.conf

# Override email recipient
./rman_backup.sh full /etc/oracle/orcl_backup.conf emergency@example.com
```

## Directory Structure

```
BACKUP_BASE/
├── orcl/
│   ├── full/
│   │   ├── 20240323_143022/
│   │   │   ├── full_*.bkp           # Full backup pieces
│   │   │   ├── arch_*.bkp           # Archive logs
│   │   │   └── cf_*.bkp             # Control file auto-backup
│   │   └── arch/
│   │       └── 20240323_150000/
│   │           ├── arch_*.bkp
│   │           └── cf_*.bkp
│   └── incr0/
│       └── 20240323_140000/
│           ├── incr0_*.bkp          # Incremental backup pieces
│           ├── arch_*.bkp
│           └── cf_*.bkp

LOG_DIR/
├── orclfull20240323_143022.log
├── orclincr020240323_140000.log
└── orclarchivelog20240323_150000.log
```

## Control File Auto-backup

The script configures control file auto-backup to store control files in the same directory as the backup files:

- **Format**: `cf_c-XXXXXXXXXX-YYYYMMDD-QQ`
- **Location**: Same timestamped directory as the backup
- **Configuration**: Session-specific, doesn't modify persistent RMAN settings

## Logging

- All backup output is captured in log files
- Log files are stored in the configured `LOG_DIR`
- Format: `${DBNAME}${BACKUP_TYPE}${TIMESTAMP}.log`
- Real-time output is also displayed on console

## Cleanup Policy

- **Obsolete backups**: Removed after 15 days (recovery window)
- **Expired backups**: Automatically deleted
- **Expired archive logs**: Automatically deleted
- Cleanup runs automatically after successful backups (except in maint mode)

## Error Handling

- Lock file prevents concurrent backups
- Failure emails sent to configured recipients
- Non-zero exit codes for scripting integration
- Detailed error messages in logs

## Security Considerations

- Script uses `set -u` to prevent undefined variable usage
- Lock files prevent race conditions
- Proper directory permissions required
- RMAN connects locally via `/` (OS authentication)

## Integration with Crontab

Example crontab entries:

```cron
# Full backup every Sunday at 1:00 AM
0 1 * * 0 /path/to/rman_backup.sh full /etc/oracle/orcl_backup.conf

# Incremental backup Monday-Saturday at 1:00 AM
0 1 * * 1-6 /path/to/rman_backup.sh incr0 /etc/oracle/orcl_backup.conf

# Archive log backup every hour
0 * * * * /path/to/rman_backup.sh archivelog /etc/oracle/orcl_backup.conf

# Maintenance every Sunday at 2:00 AM
0 2 * * 0 /path/to/rman_backup.sh maint /etc/oracle/orcl_backup.conf
```

## Troubleshooting

### Common Issues

1. **"Oracle env file not found"**
   - Ensure `$HOME/.${DBNAME}` exists and is readable
   - Database name is case-insensitive (converted to lowercase)

2. **"BACKUP_BASE and LOG_DIR must be defined"**
   - Check configuration file for missing parameters
   - Ensure config file is accessible

3. **"Another backup appears to be running"**
   - Remove stale lock file if no backup is running
   - Lock file location: `${LOG_DIR}/rman_${DBNAME}.lock`

4. **RMAN connection failures**
   - Verify Oracle environment variables are correctly set
   - Check `ORACLE_SID` matches the database name

### Log Analysis

Check the log files for detailed RMAN output:
```bash
tail -f /u01/logs/rman/orcl/orclfull*.log
```

## Support

For issues or questions:
- Check the log files for error messages
- Verify Oracle environment and RMAN connectivity
- Ensure sufficient disk space in backup directories

## License

This script is provided as-is for production use. Test thoroughly in a development environment before deploying to production.

## Version History

- **v1.0**: Initial release
  - Full, incr0, archivelog, and maint backup types
  - Channel management
  - Control file auto-backup placement
  - Automatic cleanup with 15-day retention
  - Email notifications
  - Lock file protection
```
