#!/bin/bash
# cockpit-backup — helper for the Cockpit "Folder backup" plugin
# Each configured folder is backed up to its own archive, on its own daily schedule:
#   backup-<slug>-YYYYMMDD-HHMMSS.tar.gz  (+ .meta sidecar with the original path)
# Subcommands:
#   backup [FOLDER]           back up all configured folders, or a single one
#   backup-due                back up folders whose daily time has passed (run by the timer)
#   apply-schedule            regenerate the timer's OnCalendar entries from the config
#   list                      list existing archives as JSON (with original folder)
#   restore ARCHIVE [TARGET]  restore an archive (to / or to TARGET)
#   delete ARCHIVE            delete an archive
set -euo pipefail

CONFIG="${COCKPIT_BACKUP_CONFIG:-/etc/cockpit-backup/config.json}"
DROPIN_DIR="${COCKPIT_BACKUP_DROPIN:-/etc/systemd/system/cockpit-backup.timer.d}"

die() { echo "ERROR: $*" >&2; exit 1; }

# If a backup is interrupted (page closed, tar failure, signal), remove the
# in-flight partial file and its metadata so no orphan archive is left behind.
CLEANUP_FILE=""
cleanup() {
    if [ -n "$CLEANUP_FILE" ]; then
        rm -f "$CLEANUP_FILE" "${CLEANUP_FILE%.partial}.meta"
        CLEANUP_FILE=""
    fi
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 143' INT TERM HUP

[ -f "$CONFIG" ] || die "configuration not found: $CONFIG"

cfg_get() {
    python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
key, default = sys.argv[2], sys.argv[3]
val = cfg.get(key, default)
print(val)
' "$CONFIG" "$1" "$2"
}

cfg_excludes() {
    python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
for b in cfg.get("backups", []):
    if b["folder"] == sys.argv[2]:
        for e in b.get("excludes", []):
            print(e)
        break
' "$CONFIG" "$1"
}

cfg_folders() {
    python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
backups = cfg.get("backups")
if backups is None:
    # legacy schema
    for f in cfg.get("folders", []):
        print(f)
else:
    for b in backups:
        print(b["folder"])
' "$CONFIG"
}

DEST=$(cfg_get destination /var/backups/cockpit-backup)
RETENTION=$(cfg_get retention_days 30)

# The archive must live inside DEST and match the expected name: prevents path traversal
archive_path() {
    local name="$1"
    case "$name" in
        backup-*.tar.gz) ;;
        *) die "invalid archive name: $name" ;;
    esac
    case "$name" in
        */*) die "invalid archive name: $name" ;;
    esac
    echo "$DEST/$name"
}

backup_one() {
    local folder="$1" stamp="$2"
    local slug archive tmp rel
    slug=$(printf '%s' "${folder#/}" | tr -c 'A-Za-z0-9._-' '-')
    archive="$DEST/backup-$slug-$stamp.tar.gz"
    tmp="$archive.partial"
    rel="${folder#/}"

    # Per-folder exclusions: relative to the folder (or absolute), globs allowed.
    # Archive members are relative to /, so patterns are rebased accordingly.
    local -a tar_args=()
    local ex member
    while IFS= read -r ex; do
        [ -n "$ex" ] || continue
        case "$ex" in
            /*) member="${ex#/}" ;;
            *)  member="$rel/$ex" ;;
        esac
        tar_args+=("--exclude=$member")
        echo "  Excluding: $ex"
    done < <(cfg_excludes "$folder")

    echo "Backing up $folder"
    # Write to a .partial file and rename only on success: an interrupted or
    # failed run never leaves a half-written archive visible in the UI.
    CLEANUP_FILE="$tmp"
    tar -czf "$tmp" ${tar_args[@]+"${tar_args[@]}"} -C / "$rel" \
        2> >(grep -v 'Removing leading' >&2 || true)
    python3 - "$archive.meta" "$folder" <<'EOF'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"folder": sys.argv[2]}, f)
EOF
    mv "$tmp" "$archive"
    CLEANUP_FILE=""
    echo "  Archive: $archive"
    echo "  Size: $(du -h "$archive" | cut -f1)"
}

prune() {
    # Remove backups older than each folder's retention (global default for the rest)
    echo "Pruning old backups…"
    python3 - "$CONFIG" "$DEST" "$RETENTION" <<'EOF'
import json, os, glob, sys, time

cfg = json.load(open(sys.argv[1]))
dest, default_ret = sys.argv[2], int(sys.argv[3])
retentions = {b["folder"]: int(b.get("retention_days", default_ret))
              for b in cfg.get("backups", [])}
now = time.time()

for arch in glob.glob(os.path.join(dest, "backup-*.tar.gz")):
    meta = arch + ".meta"
    folder = None
    if os.path.exists(meta):
        try:
            folder = json.load(open(meta)).get("folder")
        except Exception:
            pass
    ret = retentions.get(folder, default_ret)
    if now - os.stat(arch).st_mtime > ret * 86400:
        os.remove(arch)
        if os.path.exists(meta):
            os.remove(meta)
        print("Removed:", os.path.basename(arch))

# Leftovers from interrupted runs: stale .partial files and .meta sidecars
# whose archive never materialized (age-guarded to spare in-flight backups)
for p in glob.glob(os.path.join(dest, "backup-*.tar.gz.partial")):
    if now - os.stat(p).st_mtime > 86400:
        os.remove(p)
        print("Removed stale partial:", os.path.basename(p))
for meta in glob.glob(os.path.join(dest, "backup-*.tar.gz.meta")):
    if not os.path.exists(meta[:-5]) and now - os.stat(meta).st_mtime > 3600:
        os.remove(meta)
        print("Removed orphan meta:", os.path.basename(meta))
EOF
    echo "Done."
}

cmd_backup() {
    local only="${1:-}"
    mkdir -p "$DEST"
    local stamp count=0
    stamp=$(date +%Y%m%d-%H%M%S)

    if [ -n "$only" ]; then
        # Safety: a single-folder backup must target a configured folder
        cfg_folders | grep -Fxq -- "$only" || die "folder not in configuration: $only"
    fi

    while IFS= read -r folder; do
        [ -n "$folder" ] || continue
        if [ -n "$only" ] && [ "$folder" != "$only" ]; then
            continue
        fi
        if [ "$folder" = "/" ]; then
            echo "WARNING: / cannot be backed up, skipping" >&2
            continue
        fi
        if [ ! -e "$folder" ]; then
            echo "WARNING: $folder does not exist, skipping" >&2
            continue
        fi
        backup_one "$folder" "$stamp"
        count=$((count + 1))
    done < <(cfg_folders)

    [ "$count" -gt 0 ] || die "no valid folders to back up (check the configuration)"
    prune
}

# Called by the systemd timer at each configured time. A folder is due when its
# daily time has passed and its newest archive is older than that scheduled
# moment — so missed runs (server off) are caught up at the next firing
# (Persistent=true also fires once at boot for missed schedules).
cmd_backup_due() {
    mkdir -p "$DEST"
    local due
    due=$(python3 - "$CONFIG" "$DEST" <<'EOF'
import json, os, glob, sys, datetime

cfg = json.load(open(sys.argv[1]))
dest = sys.argv[2]
now = datetime.datetime.now()
default_time = cfg.get("time", "02:00")

newest = {}
for meta in glob.glob(os.path.join(dest, "backup-*.tar.gz.meta")):
    try:
        folder = json.load(open(meta)).get("folder")
    except Exception:
        continue
    arch = meta[:-5]
    if folder and os.path.exists(arch):
        m = os.stat(arch).st_mtime
        if m > newest.get(folder, 0):
            newest[folder] = m

for b in cfg.get("backups", []):
    if not b.get("enabled", True):
        continue
    t = b.get("time") or default_time
    try:
        hh, mm = map(int, t.split(":"))
    except ValueError:
        hh, mm = 2, 0
    sched = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
    if now < sched:
        sched -= datetime.timedelta(days=1)   # last scheduled occurrence
    if newest.get(b["folder"], 0) < sched.timestamp():
        print(b["folder"])
EOF
)
    [ -n "$due" ] || exit 0

    local stamp count=0
    stamp=$(date +%Y%m%d-%H%M%S)
    while IFS= read -r folder; do
        [ -n "$folder" ] || continue
        if [ "$folder" = "/" ]; then
            echo "WARNING: / cannot be backed up, skipping" >&2
            continue
        fi
        if [ ! -e "$folder" ]; then
            echo "WARNING: $folder does not exist, skipping" >&2
            continue
        fi
        backup_one "$folder" "$stamp"
        count=$((count + 1))
    done <<< "$due"

    [ "$count" -eq 0 ] || prune
}

# Size of a folder honoring exclude patterns (same semantics as the backup).
# Args: FOLDER [PATTERN...] — patterns relative to FOLDER or absolute, globs allowed.
cmd_estimate() {
    local folder="${1:-}"
    [ -n "$folder" ] || die "usage: estimate FOLDER [PATTERN...]"
    case "$folder" in
        /*) ;;
        *) die "folder must be an absolute path" ;;
    esac
    [ -e "$folder" ] || die "folder not found: $folder"
    shift
    python3 - "$folder" "$@" <<'EOF'
import os, sys, fnmatch, json

folder = sys.argv[1].rstrip("/") or "/"
patterns = []
for p in sys.argv[2:]:
    if p.startswith("/"):
        if p == folder or p.startswith(folder + "/"):
            p = p[len(folder) + 1:]
        else:
            continue  # absolute pattern outside the folder: never matches
    patterns.append(p.rstrip("/"))

def excluded(rel, name):
    return any(fnmatch.fnmatch(rel, p) or fnmatch.fnmatch(name, p) for p in patterns)

total = files = 0
for root, dirs, names in os.walk(folder):
    relroot = os.path.relpath(root, folder)
    def rel(n):
        return n if relroot == "." else relroot + "/" + n
    dirs[:] = [d for d in dirs if not excluded(rel(d), d)]
    for n in names:
        if excluded(rel(n), n):
            continue
        try:
            st = os.lstat(os.path.join(root, n))
        except OSError:
            continue
        total += st.st_size
        files += 1
print(json.dumps({"bytes": total, "files": files}))
EOF
}

# Regenerate the timer schedule: one OnCalendar entry per distinct configured
# time (enabled folders only). Called by the UI after every config change.
cmd_apply_schedule() {
    mkdir -p "$DROPIN_DIR"
    {
        echo "[Timer]"
        echo "OnCalendar="   # reset the base unit's default
        python3 - "$CONFIG" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
default = cfg.get("time", "02:00")
times = set()
for b in cfg.get("backups", []):
    if not b.get("enabled", True):
        continue
    t = b.get("time") or default
    try:
        hh, mm = t.split(":")
        times.add("%02d:%02d" % (int(hh), int(mm)))
    except ValueError:
        pass
if not times:
    # keep the timer valid even with nothing enabled; backup-due just no-ops
    times.add("03:00")
for t in sorted(times):
    print("OnCalendar=*-*-* %s:00" % t)
EOF
    } > "$DROPIN_DIR/override.conf"
    systemctl daemon-reload
    if systemctl is-active --quiet cockpit-backup.timer; then
        systemctl restart cockpit-backup.timer
    fi
    echo "Schedule applied:"
    grep '^OnCalendar=..' "$DROPIN_DIR/override.conf" || true
}

cmd_list() {
    python3 -c '
import json, os, glob, sys
dest = sys.argv[1]
items = []
for p in glob.glob(os.path.join(dest, "backup-*.tar.gz")):
    st = os.stat(p)
    folder = None
    meta = p + ".meta"
    if os.path.exists(meta):
        try:
            folder = json.load(open(meta)).get("folder")
        except Exception:
            pass
    items.append({
        "name": os.path.basename(p),
        "size": st.st_size,
        "mtime": int(st.st_mtime),
        "folder": folder,
    })
items.sort(key=lambda x: x["mtime"], reverse=True)
print(json.dumps(items))
' "$DEST"
}

cmd_restore() {
    local name="${1:-}" target="${2:-/}"
    [ -n "$name" ] || die "usage: restore ARCHIVE [TARGET]"
    local archive
    archive=$(archive_path "$name")
    [ -f "$archive" ] || die "archive not found: $archive"

    case "$target" in
        /*) ;;
        *) die "target must be an absolute path" ;;
    esac
    mkdir -p "$target"

    echo "Restoring $name to $target …"
    tar -xzf "$archive" -C "$target"
    echo "Restore completed."
}

cmd_delete() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: delete ARCHIVE"
    local archive
    archive=$(archive_path "$name")
    [ -f "$archive" ] || die "archive not found: $archive"
    rm -f "$archive" "$archive.meta"
    echo "Deleted: $name"
}

case "${1:-}" in
    backup)         shift; cmd_backup "${1:-}" ;;
    backup-due)     cmd_backup_due ;;
    apply-schedule) cmd_apply_schedule ;;
    list)           cmd_list ;;
    estimate)    shift; cmd_estimate "$@" ;;
    restore)     shift; cmd_restore "$@" ;;
    delete)      shift; cmd_delete "$@" ;;
    *)
        echo "Usage: $0 {backup [FOLDER]|backup-due|apply-schedule|list|estimate FOLDER [PATTERN...]|restore ARCHIVE [TARGET]|delete ARCHIVE}" >&2
        exit 2
        ;;
esac
