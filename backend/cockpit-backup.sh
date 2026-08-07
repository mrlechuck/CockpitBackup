#!/bin/bash
# cockpit-backup — helper for the Cockpit "Folder backup" plugin
# Each configured folder is backed up to its own archive, on its own daily schedule.
# Storage is per-folder: local disk (default) or Amazon S3 / S3-compatible remote.
# Remote backups are built in a temp dir, uploaded, then removed locally; a .meta
# stub in the destination keeps them visible in the UI (restore downloads them).
# Subcommands:
#   backup [FOLDER]           back up all configured folders, or a single one (trigger: manual)
#   backup-due                back up folders whose daily time has passed (run by the timer)
#   apply-schedule            regenerate the timer's OnCalendar entries from the config
#   list                      JSON: archives (local+remote) + running backups + disk space
#   estimate FOLDER [PAT...]  folder size honoring exclude patterns
#   restore ARCHIVE [TARGET]  restore an archive (remote ones are downloaded first)
#   delete ARCHIVE            delete an archive (local file and/or remote object)
#   test-s3                   check that the configured S3 bucket is reachable
#   log FOLDER                print the folder's backup log (last 500 lines)
#   clear-log FOLDER          empty the folder's backup log
set -euo pipefail

CONFIG="${COCKPIT_BACKUP_CONFIG:-/etc/cockpit-backup/config.json}"
DROPIN_DIR="${COCKPIT_BACKUP_DROPIN:-/etc/systemd/system/cockpit-backup.timer.d}"
LOG_DIR="${COCKPIT_BACKUP_LOGDIR:-/var/log/cockpit-backup}"

die() { echo "ERROR: $*" >&2; exit 1; }

slug_of() { printf '%s' "${1#/}" | tr -c 'A-Za-z0-9._-' '-'; }

log_line() {
    # log_line FOLDER TRIGGER MESSAGE
    mkdir -p "$LOG_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$2] $3" >> "$LOG_DIR/$(slug_of "$1").log"
}

# If a backup is interrupted (page closed, tar failure, signal), remove the
# in-flight partial file and its metadata so no orphan archive is left behind.
CLEANUP_FILE=""
CLEANUP_FOLDER=""
CLEANUP_TRIGGER=""
cleanup() {
    if [ -n "$CLEANUP_FILE" ]; then
        rm -f "$CLEANUP_FILE" "${CLEANUP_FILE%.partial}.meta"
        [ -n "$CLEANUP_FOLDER" ] && \
            log_line "$CLEANUP_FOLDER" "${CLEANUP_TRIGGER:-manual}" "Backup failed or was interrupted" || true
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
REMOTE_TMP="$DEST/.tmp"

# ---------- S3 remote storage ----------

s3_cfg() {
    python3 -c '
import json, sys
s3 = json.load(open(sys.argv[1])).get("s3") or {}
print(s3.get(sys.argv[2], ""))
' "$CONFIG" "$1"
}

s3_configured() {
    [ "$(s3_cfg enabled)" = "True" ] && [ -n "$(s3_cfg bucket)" ]
}

# Run the aws CLI with credentials/region/endpoint from the configuration.
# Credentials are passed via environment, never on the command line.
s3_run() {
    local -a args=("$@")
    local region endpoint
    region=$(s3_cfg region)
    endpoint=$(s3_cfg endpoint)
    [ -n "$region" ] && args+=(--region "$region")
    [ -n "$endpoint" ] && args+=(--endpoint-url "$endpoint")
    AWS_ACCESS_KEY_ID="$(s3_cfg access_key)" \
    AWS_SECRET_ACCESS_KEY="$(s3_cfg secret_key)" \
    aws "${args[@]}"
}

s3_key() {
    local prefix
    prefix=$(s3_cfg prefix)
    prefix="${prefix#/}"
    [ -n "$prefix" ] && prefix="${prefix%/}/"
    echo "${prefix}$1"
}

# Best-effort removal of the remote copy when the local archive goes away
s3_delete_remote() {
    local name="$1"
    s3_configured || return 0
    command -v aws >/dev/null || return 0
    s3_run s3 rm "s3://$(s3_cfg bucket)/$(s3_key "$name")" --only-show-errors 2>/dev/null || true
}

# Does this folder's configuration ask for S3 remote storage?
wants_s3() {
    python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
for b in cfg.get("backups", []):
    if b["folder"] == sys.argv[2]:
        print(bool(b.get("s3")))
        break
else:
    print(False)
' "$CONFIG" "$1"
}

meta_is_remote() {
    [ -f "$1" ] || return 1
    [ "$(python3 -c 'import json,sys; print(bool(json.load(open(sys.argv[1])).get("remote")))' "$1")" = "True" ]
}

# ---------- Core backup ----------

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
    local folder="$1" stamp="$2" trigger="${3:-manual}"
    local slug name archive tmp workdir rel start_ts remote
    slug=$(slug_of "$folder")
    name="backup-$slug-$stamp.tar.gz"
    archive="$DEST/$name"
    rel="${folder#/}"

    remote="false"
    if [ "$(wants_s3 "$folder")" = "True" ]; then
        if ! s3_configured; then
            echo "  NOTE: S3 storage requested but S3 is disabled, storing locally" >&2
            log_line "$folder" "$trigger" "S3 requested but S3 is disabled: storing locally"
        elif ! command -v aws >/dev/null; then
            echo "  WARNING: aws CLI not installed, storing locally instead" >&2
            log_line "$folder" "$trigger" "S3 requested but aws CLI missing: storing locally"
        else
            remote="true"
        fi
    fi

    # Remote backups are built in a temp dir and never land in the destination
    workdir="$DEST"
    if [ "$remote" = "true" ]; then
        workdir="$REMOTE_TMP"
        mkdir -p "$workdir"
    fi
    tmp="$workdir/$name.partial"

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
    start_ts=$(date +%s)
    log_line "$folder" "$trigger" "Backup started$([ "$remote" = "true" ] && echo ' (S3 remote)')"

    # The .meta is written before tar starts: together with the .partial file it
    # marks an in-progress backup (reported by `list` as "running"). tar writes
    # to .partial: an interrupted or failed run never leaves a half-written
    # archive visible in the UI.
    python3 - "$workdir/$name.meta" "$folder" "$trigger" "$remote" <<'EOF'
import json, sys
meta = {"folder": sys.argv[2], "trigger": sys.argv[3]}
if sys.argv[4] == "true":
    meta["s3"] = True     # lets the UI announce the run as an S3 backup
with open(sys.argv[1], "w") as f:
    json.dump(meta, f)
EOF
    CLEANUP_FILE="$tmp"
    CLEANUP_FOLDER="$folder"
    CLEANUP_TRIGGER="$trigger"
    tar -czf "$tmp" ${tar_args[@]+"${tar_args[@]}"} -C / "$rel" \
        2> >(grep -v 'Removing leading' >&2 || true)

    local size_h size_b dur tar_dur
    size_h=$(du -h "$tmp" | cut -f1)
    size_b=$(wc -c < "$tmp" | tr -d ' ')
    tar_dur=$(( $(date +%s) - start_ts ))

    if [ "$remote" = "true" ]; then
        local bucket key up_start
        bucket=$(s3_cfg bucket)
        key=$(s3_key "$name")
        log_line "$folder" "$trigger" "Archive created: $name ($size_h) in ${tar_dur}s"
        log_line "$folder" "$trigger" "S3 upload started: $name → s3://$bucket/$key"
        echo "  Uploading to S3: s3://$bucket/$key ($size_h)"
        up_start=$(date +%s)
        if s3_run s3 cp "$tmp" "s3://$bucket/$key" --only-show-errors; then
            # Meta stub in the destination keeps the remote archive visible in the UI
            python3 - "$archive.meta" "$folder" "$trigger" "$size_b" <<'EOF'
import json, sys, time
with open(sys.argv[1], "w") as f:
    json.dump({"folder": sys.argv[2], "trigger": sys.argv[3],
               "remote": True, "s3": True,
               "size": int(sys.argv[4]), "mtime": int(time.time())}, f)
EOF
            local up_dur
            up_dur=$(( $(date +%s) - up_start ))
            log_line "$folder" "$trigger" "S3 upload completed: $name in ${up_dur}s"
            rm -f "$tmp" "$workdir/$name.meta"
            CLEANUP_FILE=""
            CLEANUP_FOLDER=""
            dur=$(( $(date +%s) - start_ts ))
            log_line "$folder" "$trigger" "Local temp copy deleted — done on S3 ($size_h, ${dur}s total)"
            echo "  Uploaded and removed locally."
        else
            # Upload failed: keep the data by falling back to local storage
            mv "$tmp" "$archive"
            mv "$workdir/$name.meta" "$archive.meta"
            CLEANUP_FILE=""
            CLEANUP_FOLDER=""
            log_line "$folder" "$trigger" "S3 upload FAILED: $name kept locally ($size_h)"
            echo "  WARNING: S3 upload failed, archive kept locally" >&2
        fi
    else
        mv "$tmp" "$archive"
        CLEANUP_FILE=""
        CLEANUP_FOLDER=""
        dur=$(( $(date +%s) - start_ts ))
        log_line "$folder" "$trigger" "Completed: $name ($size_h) in ${dur}s"
        echo "  Archive: $archive"
        echo "  Size: $size_h"
    fi
}

prune() {
    # Remove backups older than each folder's retention (global default for the rest)
    echo "Pruning old backups…"
    local out
    out=$(python3 - "$CONFIG" "$DEST" "$RETENTION" <<'EOF'
import json, os, glob, sys, time

cfg = json.load(open(sys.argv[1]))
dest, default_ret = sys.argv[2], int(sys.argv[3])
retentions = {b["folder"]: int(b.get("retention_days", default_ret))
              for b in cfg.get("backups", [])}
now = time.time()

def read_meta(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}

# Local archives
for arch in glob.glob(os.path.join(dest, "backup-*.tar.gz")):
    meta = read_meta(arch + ".meta")
    ret = retentions.get(meta.get("folder"), default_ret)
    if now - os.stat(arch).st_mtime > ret * 86400:
        os.remove(arch)
        if os.path.exists(arch + ".meta"):
            os.remove(arch + ".meta")
        print("Removed:", os.path.basename(arch))

# Expired remote archives (meta stubs): print for the shell to delete on S3
for mp in glob.glob(os.path.join(dest, "backup-*.tar.gz.meta")):
    meta = read_meta(mp)
    if not meta.get("remote"):
        continue
    ret = retentions.get(meta.get("folder"), default_ret)
    if now - meta.get("mtime", now) > ret * 86400:
        print("RemoteExpired:", os.path.basename(mp)[:-5])

# Leftovers from interrupted runs: stale .partial files and .meta sidecars
# whose archive never materialized (age-guarded to spare in-flight backups)
for pat in ("backup-*.tar.gz.partial", os.path.join(".tmp", "backup-*.tar.gz.partial")):
    for p in glob.glob(os.path.join(dest, pat)):
        if now - os.stat(p).st_mtime > 86400:
            os.remove(p)
            print("Removed stale partial:", os.path.basename(p))
for pat in ("backup-*.tar.gz.meta", os.path.join(".tmp", "backup-*.tar.gz.meta")):
    for mp in glob.glob(os.path.join(dest, pat)):
        meta = read_meta(mp)
        if meta.get("remote"):
            continue
        arch = mp[:-5]
        if not os.path.exists(arch) and not os.path.exists(arch + ".partial") \
                and now - os.stat(mp).st_mtime > 3600:
            os.remove(mp)
            print("Removed orphan meta:", os.path.basename(mp))
EOF
)
    if [ -n "$out" ]; then
        echo "$out" | grep -v '^RemoteExpired: ' || true
        # Delete expired remote objects and their meta stubs (best effort)
        if s3_configured && command -v aws >/dev/null; then
            echo "$out" | sed -n 's/^RemoteExpired: //p' | while IFS= read -r n; do
                s3_delete_remote "$n"
                rm -f "$DEST/$n.meta"
                echo "Removed remote: $n"
            done
        fi
        # Mirror local pruning of uploaded archives on the bucket
        if s3_configured; then
            echo "$out" | sed -n 's/^Removed: //p' | while IFS= read -r n; do
                s3_delete_remote "$n"
            done
        fi
    fi
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
        backup_one "$folder" "$stamp" "manual"
        count=$((count + 1))
    done < <(cfg_folders)

    [ "$count" -gt 0 ] || die "no valid folders to back up (check the configuration)"
    prune
}

# Called by the systemd timer at each configured time. A folder is due when its
# daily time has passed and its newest archive is older than that scheduled
# moment. Trigger is "scheduled" when we are within a few minutes of the exact
# time, "catchup" when a missed occurrence is being recovered (server was off,
# schedule changed, or the folder is new).
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
for meta_path in glob.glob(os.path.join(dest, "backup-*.tar.gz.meta")):
    try:
        meta = json.load(open(meta_path))
    except Exception:
        continue
    folder = meta.get("folder")
    if not folder:
        continue
    arch = meta_path[:-5]
    if meta.get("remote"):
        m = meta.get("mtime", 0)
    elif os.path.exists(arch):
        m = os.stat(arch).st_mtime
    else:
        continue
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
        trigger = "scheduled" if (now - sched).total_seconds() <= 180 else "catchup"
        print(trigger + "\t" + b["folder"])
EOF
)
    [ -n "$due" ] || exit 0

    local stamp count=0 trigger folder
    stamp=$(date +%Y%m%d-%H%M%S)
    while IFS=$'\t' read -r trigger folder; do
        [ -n "$folder" ] || continue
        if [ "$folder" = "/" ]; then
            echo "WARNING: / cannot be backed up, skipping" >&2
            continue
        fi
        if [ ! -e "$folder" ]; then
            echo "WARNING: $folder does not exist, skipping" >&2
            continue
        fi
        backup_one "$folder" "$stamp" "$trigger"
        count=$((count + 1))
    done <<< "$due"

    [ "$count" -eq 0 ] || prune
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
import json, os, glob, sys, shutil
dest = sys.argv[1]

def read_meta(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}

archives = []
seen = set()
for p in glob.glob(os.path.join(dest, "backup-*.tar.gz")):
    st = os.stat(p)
    meta = read_meta(p + ".meta")
    seen.add(os.path.basename(p))
    archives.append({
        "name": os.path.basename(p),
        "size": st.st_size,
        "mtime": int(st.st_mtime),
        "folder": meta.get("folder"),
        "trigger": meta.get("trigger"),
        "remote": False,
    })

# Remote archives: meta stubs without a local file
for mp in glob.glob(os.path.join(dest, "backup-*.tar.gz.meta")):
    meta = read_meta(mp)
    name = os.path.basename(mp)[:-5]
    if not meta.get("remote") or name in seen:
        continue
    archives.append({
        "name": name,
        "size": meta.get("size", 0),
        "mtime": meta.get("mtime", 0),
        "folder": meta.get("folder"),
        "trigger": meta.get("trigger"),
        "remote": True,
    })

archives.sort(key=lambda x: x["mtime"], reverse=True)

# In-progress backups: a .partial file plus the .meta written at start
# (remote ones run inside .tmp/)
running = []
for pat in ("backup-*.tar.gz.partial", os.path.join(".tmp", "backup-*.tar.gz.partial")):
    for p in glob.glob(os.path.join(dest, pat)):
        meta_path = p[:-8] + ".meta"
        if not os.path.exists(meta_path):
            continue
        meta = read_meta(meta_path)
        if meta.get("folder"):
            running.append({
                "name": os.path.basename(p)[:-8],
                "folder": meta.get("folder"),
                "trigger": meta.get("trigger"),
                "remote": bool(meta.get("s3")),
            })

# Free space on the destination filesystem (nearest existing parent)
p = dest
while p and not os.path.exists(p):
    p = os.path.dirname(p)
try:
    du = shutil.disk_usage(p or "/")
    disk = {"free": du.free, "total": du.total}
except Exception:
    disk = None

print(json.dumps({"archives": archives, "running": running, "disk": disk}))
' "$DEST"
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

cmd_restore() {
    local name="${1:-}" target="${2:-/}"
    [ -n "$name" ] || die "usage: restore ARCHIVE [TARGET]"
    local archive
    archive=$(archive_path "$name")

    case "$target" in
        /*) ;;
        *) die "target must be an absolute path" ;;
    esac
    mkdir -p "$target"

    if [ -f "$archive" ]; then
        echo "Restoring $name to $target …"
        tar -xzf "$archive" -C "$target"
    elif meta_is_remote "$archive.meta"; then
        s3_configured || die "archive is stored on S3 but S3 is not configured"
        command -v aws >/dev/null || die "aws CLI is not installed"
        local tmpd
        tmpd=$(mktemp -d)
        echo "Downloading from S3: $name …"
        if ! s3_run s3 cp "s3://$(s3_cfg bucket)/$(s3_key "$name")" "$tmpd/$name" --only-show-errors; then
            rm -rf "$tmpd"
            die "download from S3 failed"
        fi
        echo "Restoring $name to $target …"
        tar -xzf "$tmpd/$name" -C "$target"
        rm -rf "$tmpd"
    else
        die "archive not found: $archive"
    fi
    echo "Restore completed."
}

cmd_delete() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: delete ARCHIVE"
    local archive
    archive=$(archive_path "$name")

    if [ ! -f "$archive" ] && [ ! -f "$archive.meta" ]; then
        die "archive not found: $archive"
    fi
    if meta_is_remote "$archive.meta"; then
        # Never drop the list entry while the remote object cannot be removed:
        # that would leave an invisible orphan on the bucket
        s3_configured || die "archive is stored on S3: enable S3 first so the remote copy can be removed too"
        command -v aws >/dev/null || die "aws CLI is not installed: cannot remove the remote copy"
        s3_run s3 rm "s3://$(s3_cfg bucket)/$(s3_key "$name")" --only-show-errors \
            || die "failed to remove the remote copy from S3"
    fi
    rm -f "$archive" "$archive.meta"
    echo "Deleted: $name"
}

cmd_test_s3() {
    s3_configured || die "S3 is not enabled or the bucket is not set (save the settings first)"
    command -v aws >/dev/null || die "aws CLI is not installed (e.g. apt install awscli)"
    local bucket
    bucket=$(s3_cfg bucket)
    s3_run s3 ls "s3://$bucket" --page-size 5 >/dev/null
    echo "S3 connection OK: bucket '$bucket' is reachable"
}

cmd_log() {
    local folder="${1:-}"
    [ -n "$folder" ] || die "usage: log FOLDER"
    local f="$LOG_DIR/$(slug_of "$folder").log"
    if [ -f "$f" ]; then
        tail -n 500 "$f"
    fi
}

cmd_clear_log() {
    local folder="${1:-}"
    [ -n "$folder" ] || die "usage: clear-log FOLDER"
    local f="$LOG_DIR/$(slug_of "$folder").log"
    : > "$f" 2>/dev/null || true
    echo "Log cleared."
}

case "${1:-}" in
    backup)         shift; cmd_backup "${1:-}" ;;
    backup-due)     cmd_backup_due ;;
    apply-schedule) cmd_apply_schedule ;;
    list)           cmd_list ;;
    estimate)       shift; cmd_estimate "$@" ;;
    restore)        shift; cmd_restore "$@" ;;
    delete)         shift; cmd_delete "$@" ;;
    test-s3)        cmd_test_s3 ;;
    log)            shift; cmd_log "$@" ;;
    clear-log)      shift; cmd_clear_log "$@" ;;
    *)
        echo "Usage: $0 {backup [FOLDER]|backup-due|apply-schedule|list|estimate FOLDER [PATTERN...]|restore ARCHIVE [TARGET]|delete ARCHIVE|test-s3|log FOLDER|clear-log FOLDER}" >&2
        exit 2
        ;;
esac
