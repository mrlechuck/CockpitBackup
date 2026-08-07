# Cockpit Backup — folder backup plugin

A [Cockpit](https://cockpit-project.org/) plugin to manage **a separate backup for each
folder**, each with its own schedule, right from the web interface:

- **Main view**: list of configured backups, with add, edit (title, folder, time,
  retention) and remove
- **Per-folder toggle**: each automatic backup can be enabled or disabled individually,
  directly from the list
- **Per-folder daily time**: each configuration decides when its backup runs; missed
  backups (server off) run at the first useful check
- **Detail view** for each folder: archives with date and size, manual backup with
  live output, restore and delete
- **Restore** to the original location or to an alternate folder
- **Per-folder retention**: independent number of days to keep
- **Exclusions**: skip subfolders or file patterns (e.g. `cache`, `*.log`) per backup
- **Optional title** per backup and a **size calculator** in the add/edit dialog that
  shows the current folder size with exclusions applied

## Requirements

- Linux with Cockpit installed (Debian/Ubuntu: `apt install cockpit` — Fedora/RHEL: `dnf install cockpit`)
- `python3`, `tar`, `systemd` (preinstalled on every modern distro)

## Installation

Copy this folder to your Linux server, then:

```bash
sudo ./install.sh
```

Open Cockpit at `https://<server-ip>:9090`, log in and find **Backup** in the side menu.
Operations require administrative access (the "Limited access / Turn on administrative
access" button at the top).

## First use

1. In **Settings** set the destination folder, then **Save settings**
2. Click **Add backup**: folder (absolute path), daily time and retention days
3. The automatic backup is active right away; you can disable it with the toggle on the row
4. (Optional) Open the folder's detail view and try **Backup now**

## How it works

| Component | Path |
|---|---|
| Cockpit frontend | `/usr/share/cockpit/backup/` |
| Backend script | `/usr/local/libexec/cockpit-backup/cockpit-backup.sh` |
| Configuration | `/etc/cockpit-backup/config.json` |
| systemd units | `cockpit-backup.service` + `cockpit-backup.timer` |
| Archives | `backup-<folder>-YYYYMMDD-HHMMSS.tar.gz` + `.meta` sidecar |

### Per-folder scheduling

The systemd timer fires **exactly at the configured times**: `apply-schedule`
generates one `OnCalendar` entry per distinct backup time (enabled folders only)
and the UI regenerates them automatically after every configuration change.
Each firing runs `backup-due`, which backs up the folders whose daily time has
passed and whose newest archive is older than that scheduled moment. This means:

- each folder starts at its own time (systemd accuracy: within a minute)
- no polling: nothing runs between the scheduled times
- if the server was off at the scheduled time, `Persistent=true` fires the timer
  at boot and the missed backups catch up (anacron-style)
- a manual backup counts as the day's backup: the automatic one does not repeat

Times are interpreted in the **server's timezone** (check with `timedatectl`).
The timer is enabled by `install.sh`; per-folder enabling/disabling is done from
the UI (the `enabled` field). If the timer is not running, the UI shows a warning.

### Archives

Each run creates **one archive per folder** (e.g. `backup-var-www-20260807-020000.tar.gz`).
Next to each archive there is a `.meta` file with the original path, used by the UI
for grouping and to show where the restore will go. Archives are plain `tar.gz` files
with paths relative to `/`: they can also be restored by hand
(`tar -xzf archive.tar.gz -C /`), without depending on the plugin.

If you remove a configuration, its archives are **not** deleted: they remain visible
in the "Other archives" section and can still be restored. Retention cleanup uses each
folder's configured days (global default for orphaned archives).

### Configuration format

```json
{
    "destination": "/var/backups/cockpit-backup",
    "retention_days": 30,
    "backups": [
        { "folder": "/etc", "time": "02:00", "retention_days": 30, "enabled": true,
          "title": "System configuration" },
        { "folder": "/var/www", "time": "03:30", "retention_days": 14, "enabled": false,
          "excludes": ["cache", "logs/tmp", "*.log"], "title": "Web sites" }
    ]
}
```

The legacy format with `"folders": [...]` is migrated automatically on first save.

`excludes` entries are passed to `tar --exclude`: paths are relative to the backed-up
folder (absolute paths work too) and glob wildcards are supported. A matching
directory is skipped together with its whole content.

### Command-line usage

```bash
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh backup
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh backup /var/www
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh backup-due
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh list
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh estimate /var/www cache '*.log'
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh restore backup-var-www-20260807-020000.tar.gz
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh restore backup-var-www-20260807-020000.tar.gz /tmp/test-restore
```

## Uninstall

```bash
sudo ./uninstall.sh
```

Existing configuration and archives are **not** deleted.

## Notes

- Restoring to the original location **overwrites** existing files (files created
  after the backup are left untouched).
- The backup destination should live on a different disk than the data (or be synced
  elsewhere) to be a real backup.
