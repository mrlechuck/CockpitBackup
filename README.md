<p align="center">
  <img src="plugin/icon.svg" width="88" alt="Cockpit Backup">
</p>

<h1 align="center">Cockpit Backup</h1>

<p align="center">
  Per-folder daily backups with restore, right inside <a href="https://cockpit-project.org/">Cockpit</a>.
</p>

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
- **Per-folder backup log** in the detail view (start/finish, size, duration,
  trigger), with a clear-log button; logs live in `/var/log/cockpit-backup/`
- **Live progress**: while a backup runs, a strip under its row shows spinner +
  phase + "step N of M" + percentage + ETA (scan → backup → S3 upload as
  applicable). The state comes from the server, so it survives page reloads and
  disappears only when the backup actually ends
- **Restore controls**: the restore dialog shows a live phase line (S3 download →
  extract, with "member N of M" for chains, percentage and ETA), streams its
  output, ends with an OK button, and its Cancel actually aborts an in-progress
  restore
- **Catch-up marker**: archives created by recovering a missed schedule carry an
  info icon with an explanatory tooltip
- **S3 remote storage**: per-folder choice between local disk and Amazon S3 (or any
  S3-compatible service via custom endpoint). Remote backups are built in a temp
  folder, uploaded and removed locally; the archive list shows a Local/S3 badge and
  restore downloads them transparently
- **Archive download**: every archive has a Download button. Full/Baseline
  archives stream as they are (S3 ones are fetched from the bucket into a
  temporary server-side cache first). Downloading a **Delta** rebuilds the whole
  chain state up to that point — local or S3 — into a temporary combined
  archive, so what you get is the complete folder as of that backup. The cache
  cleans itself after an hour
- **Incremental backups**: per-folder choice between a full archive every time and
  an incremental chain — a periodic full plus daily archives containing **only what
  changed** since the previous backup. Restore transparently recombines the whole
  chain, deletions included

## Requirements

- Linux with Cockpit installed (Debian/Ubuntu: `apt install cockpit` — Fedora/RHEL: `dnf install cockpit`)
- `python3`, `tar`, `systemd` (preinstalled on every modern distro)
- `aws` CLI (only for S3 remote storage — Debian/Ubuntu: `apt install awscli`)
- `pigz` (optional, recommended: parallel gzip, used automatically when present —
  makes backups, consolidation and restores ~4× faster on multi-core boards —
  Debian/Ubuntu: `apt install pigz`)

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

### Multiple runs per day and tiered (GFS) retention

Each backup can have **several daily times** (e.g. 02:00 and 14:00), run
**every N hours** (`"every_hours": 3` → 00:00, 03:00, …) or even sub-hourly
(`"every_minutes": 30` → :00 and :30 of every hour; any divisor of 60 works)
and, instead of the flat
"keep N days", a **tiered thinning policy**: a list of independent rules, each
"keep the newest K backups per calendar period, looking back S periods from now":

```json
"every_hours": 1,
"retention": [
    { "keep": 1, "per": "hour",  "span": 24 },
    { "keep": 1, "per": "day",   "span": 7 },
    { "keep": 1, "per": "week",  "span": 4 },
    { "keep": 1, "per": "month", "span": 12 }
]
```

Reading: hourlies for the last day, dailies for the last week, weeklies for the
last month, monthlies for the last year. `per` is one of `hour|day|week|month|year`.
Rules **overlap**, restic/borg-style: every rule's window is counted back from
now, and a backup survives if *any* rule selects it (the weekly pick of the
current week is simply the newest daily). Anything older than every window is
deleted. Within a period the newest backups win (never a random pick),
incremental chains are kept or dropped as a whole, and a folder's most recent
backup is never deleted.

The older dict form (`"retention": { "daily": { "keep": 2, "days": 7 }, … }`)
is still accepted and maps onto the same overlapping rules; flat
`retention_days` entries are untouched.

### Per-folder scheduling

The systemd timer fires **exactly at the configured times**: `apply-schedule`
generates one `OnCalendar` entry per distinct backup time (enabled folders only,
`every_hours` entries contribute their hourly slots) and the UI regenerates them
automatically after every configuration change.
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

### Incremental backups

Set a backup's **Backup mode** to "Incremental" in its add/edit dialog. From then on
the folder is backed up as a **chain**:

- a **full** archive (`…-full.tar.gz`) starts the chain, and a new one is created
  every *N* days ("New full backup every", default 7);
- between fulls, each run produces an **incremental** archive (`…-incr.tar.gz`)
  containing only the files that are new or changed since the previous backup —
  detected via GNU tar's `--listed-incremental` snapshots, kept in
  `<destination>/.snar/`. Deleted files are recorded too;
- the archive list shows a **Full/Incr badge** on each archive of an incremental
  folder.

**Restore stays one click**: pick any archive and the backend automatically extracts
the chain's full plus every incremental up to that point, in order, propagating
deletions — the target ends up exactly as the folder was at that backup's time.
(A manual `tar -xzf` of each member with `--listed-incremental=/dev/null`, from the
full onwards, does the same.)

Safety rules, all automatic:

- retention expires a chain **only as a whole**, once its newest member is older
  than the configured days — the full is never pruned out from under its
  incrementals (so with "full every" larger than retention, fulls are kept longer);
- deleting an archive other backups depend on is refused; deleting the chain's tip
  resets the chain;
- the next run falls back to a **full** whenever the chain cannot be trusted:
  first run, missing/corrupted snapshot, a deleted chain member, changed
  exclusions, or the folder being re-pointed;
- a failed or interrupted run never corrupts the chain — tar works on a copy of
  the snapshot, promoted only after the archive is safely stored;
- works with **S3 storage** too: snapshots stay local, chain restore downloads
  every needed member.

### Consolidation (optional, per folder)

Without consolidation, retention treats a chain as one unit: "keep 1 per week"
keeps one **chain** per week — physically the Baseline plus all its Deltas
(~7 files with a daily schedule). Enable **"Consolidate finished chains per
retention"** in the add/edit dialog to get literally what the policy says:

- as soon as a chain is **finished** (a new Baseline has started), the retention
  policy — every tier: hours, days, weeks, months, years — selects which restore
  points of that chain survive, with the same bucket algorithm used for pruning
  (per calendar bucket, the newest points win: with `1/week` that is the last
  backup of each ISO week);
- each selected point is **materialized as a standalone Full**, rebuilt from the
  chain (deletions included) and dated at the point's original time — so it keeps
  aging correctly through the week/month/year tiers;
- everything else in the chain is deleted (from S3 too). The **active** chain
  keeps its daily Deltas until the next Baseline starts.

The synthetic Full is built and verified **before** anything is deleted; any
failure (corrupt member, failed upload) rolls back and leaves the chain intact.
Example: daily backups, `keep 1/week for 4 weeks` → after consolidation each past
week is exactly **one** Full dated at its last backup.

### S3 remote storage

Enable it in the **Remote storage (S3)** card: bucket, region, credentials, and
optionally a key prefix and a custom endpoint (MinIO, Backblaze B2, Wasabi, …).
Then set a backup's **Storage** to "Amazon S3" in its add/edit dialog. How it works:

- the archive is built in `<destination>/.tmp/`, uploaded with the `aws` CLI
  (multipart for large files), then **removed from the local disk**
- a small `.meta` stub keeps the remote archive visible in the UI (S3 badge);
  **restore** downloads it to a temp dir transparently
- if the upload fails, the archive is kept locally as a fallback (logged)
- retention and manual deletions also remove the remote objects
- credentials live in `/etc/cockpit-backup/config.json` (root-only, mode 600) and
  are passed to `aws` via environment, never on the command line

### Configuration format

```json
{
    "destination": "/var/backups/cockpit-backup",
    "retention_days": 30,
    "s3": {
        "enabled": true,
        "bucket": "my-backup-bucket",
        "region": "eu-south-1",
        "prefix": "srv1/",
        "endpoint": "",
        "access_key": "AKIA…",
        "secret_key": "…"
    },
    "backups": [
        { "folder": "/etc", "time": "02:00", "retention_days": 30, "enabled": true,
          "title": "System configuration", "s3": true },
        { "folder": "/var/www", "time": "03:30", "retention_days": 14, "enabled": false,
          "excludes": ["cache", "logs/tmp", "*.log"], "title": "Web sites",
          "mode": "incremental", "full_every": 7 }
    ]
}
```

`mode` is `"full"` (default when absent) or `"incremental"`; `full_every` is the
number of days between full backups of an incremental chain (default 7).

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
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh consolidate
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh test-s3
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh log /var/www
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh clear-log /var/www
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
