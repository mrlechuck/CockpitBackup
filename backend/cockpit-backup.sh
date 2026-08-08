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
CLEANUP_SNAR=""
RESTORE_TMPD=""
cleanup() {
    if [ -n "$CLEANUP_FILE" ]; then
        rm -f "$CLEANUP_FILE" "${CLEANUP_FILE%.partial}.meta"
        [ -n "$CLEANUP_FOLDER" ] && \
            log_line "$CLEANUP_FOLDER" "${CLEANUP_TRIGGER:-manual}" "Backup failed or was interrupted" || true
        CLEANUP_FILE=""
    fi
    # The committed .snar/.chain are only ever advanced on success, so dropping
    # the work copy leaves the incremental chain exactly as before the run
    if [ -n "$CLEANUP_SNAR" ]; then
        rm -f "$CLEANUP_SNAR"
        CLEANUP_SNAR=""
    fi
    if [ -n "$RESTORE_TMPD" ]; then
        rm -rf "$RESTORE_TMPD"
        RESTORE_TMPD=""
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

cfg_entry_get() {
    # cfg_entry_get FOLDER KEY DEFAULT — per-entry option with fallback
    python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
for b in cfg.get("backups", []):
    if b["folder"] == sys.argv[2]:
        print(b.get(sys.argv[3], sys.argv[4]))
        break
else:
    print(sys.argv[4])
' "$CONFIG" "$1" "$2" "$3"
}

DEST=$(cfg_get destination /var/backups/cockpit-backup)
RETENTION=$(cfg_get retention_days 30)
REMOTE_TMP="$DEST/.tmp"
SNAR_DIR="$DEST/.snar"

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

# ---------- Incremental chains ----------
# An "incremental" folder is backed up as a chain: a periodic full (level 0,
# every full_every days) followed by incrementals (level 1), each storing only
# what changed since the previous chain member (GNU tar --listed-incremental).
# Per-folder chain state lives in $SNAR_DIR: <slug>.snar (tar's snapshot,
# advanced on every successful member) and <slug>.chain (JSON describing the
# current chain). Both are local even for S3 folders.

excludes_hash() { cfg_excludes "$1" | sha256sum | cut -d' ' -f1; }

# read_chain SLUG → "full<TAB>prev<TAB>folder<TAB>started<TAB>hash" (nothing when absent/corrupt)
read_chain() {
    python3 - "$SNAR_DIR/$1.chain" <<'EOF'
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    print("%s\t%s\t%s\t%d\t%s" % (c["full"], c["prev"], c["folder"],
                                  int(c["started"]), c["excludes_hash"]))
except Exception:
    pass
EOF
}

write_chain() {   # write_chain SLUG FULL PREV FOLDER STARTED HASH
    python3 - "$SNAR_DIR/$1.chain" "$2" "$3" "$4" "$5" "$6" <<'EOF'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"full": sys.argv[2], "prev": sys.argv[3], "folder": sys.argv[4],
               "started": int(sys.argv[5]), "excludes_hash": sys.argv[6]}, f)
EOF
}

# decide_level FOLDER SLUG → "0" (start a new chain with a full) or
# "1<TAB>prev<TAB>full<TAB>started<TAB>hash" (incremental against prev).
# Anything suspicious falls back to a full: that is always a safe answer.
decide_level() {
    local folder="$1" slug="$2"
    [ -s "$SNAR_DIR/$slug.snar" ] || { echo 0; return; }
    local line
    line=$(read_chain "$slug")
    [ -n "$line" ] || { echo 0; return; }
    local c_full c_prev c_folder c_started c_hash
    IFS=$'\t' read -r c_full c_prev c_folder c_started c_hash <<< "$line"
    # A slug can collide or a folder be re-pointed: the chain must be ours
    [ "$c_folder" = "$folder" ] || { echo 0; return; }
    # The full and the previous member must still exist, locally or as a
    # remote stub (intermediate members are protected by the delete guard)
    { [ -f "$DEST/$c_full" ] || [ -f "$DEST/$c_full.meta" ]; } || { echo 0; return; }
    { [ -f "$DEST/$c_prev" ] || [ -f "$DEST/$c_prev.meta" ]; } || { echo 0; return; }
    # A pattern added mid-chain would make a chain restore DELETE the newly
    # excluded files, so any change to the exclusions restarts the chain
    [ "$(excludes_hash "$folder")" = "$c_hash" ] || { echo 0; return; }
    local full_every
    full_every=$(cfg_entry_get "$folder" full_every 7)
    case "$full_every" in ''|*[!0-9]*) full_every=7 ;; esac
    [ "$full_every" -ge 1 ] || full_every=1
    if [ $(( $(date +%s) - c_started )) -ge $(( full_every * 86400 )) ]; then
        echo 0
        return
    fi
    printf '1\t%s\t%s\t%s\t%s\n' "$c_prev" "$c_full" "$c_started" "$c_hash"
}

# Commit the chain state after an archive lands. Called from backup_one's
# success paths and dynamically scoped over its locals: the .snar/.chain pair
# only ever advances here, so an interrupted run leaves the chain intact.
chain_commit() {
    $incremental || return 0
    mv "$snar_work" "$SNAR_DIR/$slug.snar"
    if [ "$level" -eq 1 ]; then
        write_chain "$slug" "$chain_full" "$name" "$folder" "$chain_started" "$chain_hash"
    else
        write_chain "$slug" "$name" "$name" "$folder" "$(date +%s)" "$(excludes_hash "$folder")"
    fi
    CLEANUP_SNAR=""
}

backup_one() {
    local folder="$1" stamp="$2" trigger="${3:-manual}"
    local slug name archive tmp workdir rel start_ts remote
    slug=$(slug_of "$folder")
    rel="${folder#/}"

    # Incremental mode: pick the level for this run. Classic folders keep the
    # unsuffixed archive name; chain members are tagged -full / -incr (the
    # .meta stays the source of truth, the suffix is cosmetic).
    local incremental=false level=0 base="" chain_full="" chain_started="" chain_hash=""
    if [ "$(cfg_entry_get "$folder" mode full)" = "incremental" ]; then
        incremental=true
        mkdir -p "$SNAR_DIR"
        local decision
        decision=$(decide_level "$folder" "$slug")
        IFS=$'\t' read -r level base chain_full chain_started chain_hash <<< "$decision"
    fi
    local suffix=""
    if $incremental; then
        [ "$level" = "1" ] && suffix="-incr" || suffix="-full"
    fi
    name="backup-$slug-$stamp$suffix.tar.gz"
    archive="$DEST/$name"

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

    local -a tar_args=()

    # Incremental runs work on a COPY of the committed snapshot: tar mutates
    # only the copy, which chain_commit promotes on success (a failed or
    # interrupted run therefore never corrupts the chain).
    local snar_work=""
    if $incremental; then
        snar_work="$SNAR_DIR/$slug.snar.work"
        if [ "$level" = "1" ]; then
            cp "$SNAR_DIR/$slug.snar" "$snar_work"
        else
            rm -f "$snar_work"
        fi
        CLEANUP_SNAR="$snar_work"
        # --no-check-device avoids spurious full re-dumps after reboots or
        # device renumbering (LVM, btrfs)
        tar_args+=("--listed-incremental=$snar_work" --no-check-device)
    fi

    # Per-folder exclusions: relative to the folder (or absolute), globs allowed.
    # Archive members are relative to /, so patterns are rebased accordingly.
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

    # Chain identity recorded in the .meta: level 0 starts a chain named after
    # itself, level 1 points at its base (previous member) and its chain's full
    local meta_level="" meta_chain="" meta_base=""
    if $incremental; then
        meta_level="$level"
        if [ "$level" = "1" ]; then
            meta_chain="$chain_full"
            meta_base="$base"
        else
            meta_chain="$name"
        fi
    fi
    local mode_note=""
    if $incremental; then
        [ "$level" = "1" ] && mode_note=" (incremental, chain $chain_full)" \
                           || mode_note=" (full, starts a new chain)"
    fi

    echo "Backing up $folder${mode_note}"
    start_ts=$(date +%s)
    log_line "$folder" "$trigger" "Backup started$([ "$remote" = "true" ] && echo ' (S3 remote)')$mode_note"

    # The .meta is written before tar starts: together with the .partial file it
    # marks an in-progress backup (reported by `list` as "running"). tar writes
    # to .partial: an interrupted or failed run never leaves a half-written
    # archive visible in the UI.
    python3 - "$workdir/$name.meta" "$folder" "$trigger" "$remote" "$meta_level" "$meta_chain" "$meta_base" <<'EOF'
import json, sys
meta = {"folder": sys.argv[2], "trigger": sys.argv[3]}
if sys.argv[4] == "true":
    meta["s3"] = True     # lets the UI announce the run as an S3 backup
if sys.argv[5] != "":
    meta["level"] = int(sys.argv[5])
    meta["chain"] = sys.argv[6]
    if sys.argv[7]:
        meta["base"] = sys.argv[7]
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
            python3 - "$archive.meta" "$folder" "$trigger" "$size_b" "$meta_level" "$meta_chain" "$meta_base" <<'EOF'
import json, sys, time
meta = {"folder": sys.argv[2], "trigger": sys.argv[3],
        "remote": True, "s3": True,
        "size": int(sys.argv[4]), "mtime": int(time.time())}
if sys.argv[5] != "":
    meta["level"] = int(sys.argv[5])
    meta["chain"] = sys.argv[6]
    if sys.argv[7]:
        meta["base"] = sys.argv[7]
with open(sys.argv[1], "w") as f:
    json.dump(meta, f)
EOF
            local up_dur
            up_dur=$(( $(date +%s) - up_start ))
            log_line "$folder" "$trigger" "S3 upload completed: $name in ${up_dur}s"
            rm -f "$tmp" "$workdir/$name.meta"
            CLEANUP_FILE=""
            CLEANUP_FOLDER=""
            chain_commit
            dur=$(( $(date +%s) - start_ts ))
            log_line "$folder" "$trigger" "Local temp copy deleted — done on S3 ($size_h, ${dur}s total)"
            echo "  Uploaded and removed locally."
        else
            # Upload failed: keep the data by falling back to local storage.
            # The archive survives locally, so the chain advances all the same.
            mv "$tmp" "$archive"
            mv "$workdir/$name.meta" "$archive.meta"
            CLEANUP_FILE=""
            CLEANUP_FOLDER=""
            chain_commit
            log_line "$folder" "$trigger" "S3 upload FAILED: $name kept locally ($size_h)"
            echo "  WARNING: S3 upload failed, archive kept locally" >&2
        fi
    else
        mv "$tmp" "$archive"
        CLEANUP_FILE=""
        CLEANUP_FOLDER=""
        chain_commit
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

# Every archive (local files and remote stubs) with its chain identity
entries = {}
for arch in glob.glob(os.path.join(dest, "backup-*.tar.gz")):
    name = os.path.basename(arch)
    meta = read_meta(arch + ".meta")
    entries[name] = {"folder": meta.get("folder"), "mtime": os.stat(arch).st_mtime,
                     "remote": False, "chain": meta.get("chain")}
for mp in glob.glob(os.path.join(dest, "backup-*.tar.gz.meta")):
    name = os.path.basename(mp)[:-5]
    if name in entries:
        continue
    meta = read_meta(mp)
    if not meta.get("remote"):
        continue
    entries[name] = {"folder": meta.get("folder"), "mtime": meta.get("mtime", now),
                     "remote": True, "chain": meta.get("chain")}

# Retention works per chain: a chain (full + its incrementals) expires only as
# a whole, once its NEWEST member has outlived the folder's retention — a full
# must never be pruned out from under incrementals that still need it. Archives
# without a chain (classic full mode, legacy) are chains of one, so for them
# this is exactly the old per-archive rule. Remote members are printed as
# "RemoteExpired:" for the shell to delete on S3.
groups = {}
for name, e in entries.items():
    groups.setdefault(e["chain"] or name, []).append(name)
for members in groups.values():
    folder = next((entries[n]["folder"] for n in members if entries[n]["folder"]), None)
    ret = retentions.get(folder, default_ret)
    newest = max(entries[n]["mtime"] for n in members)
    if now - newest <= ret * 86400:
        continue
    for n in members:
        if entries[n]["remote"]:
            print("RemoteExpired:", n)
        else:
            os.remove(os.path.join(dest, n))
            if os.path.exists(os.path.join(dest, n + ".meta")):
                os.remove(os.path.join(dest, n + ".meta"))
            print("Removed:", n)

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

# Incremental chain state: drop stale work copies left by interrupted runs
# (age-guarded to spare an in-flight backup) and reset chains whose members
# no longer exist — the next run of that folder then starts with a fresh full.
snar_dir = os.path.join(dest, ".snar")
for p in glob.glob(os.path.join(snar_dir, "*.snar.work")):
    if now - os.stat(p).st_mtime > 86400:
        os.remove(p)
        print("Removed stale snapshot copy:", os.path.basename(p))
def present(name):
    return bool(name) and (os.path.exists(os.path.join(dest, name)) or
                           os.path.exists(os.path.join(dest, name + ".meta")))
for cp in glob.glob(os.path.join(snar_dir, "*.chain")):
    c = read_meta(cp)
    if present(c.get("full")) and present(c.get("prev")):
        continue
    slug = os.path.basename(cp)[:-6]
    for f in (cp, os.path.join(snar_dir, slug + ".snar")):
        try:
            os.remove(f)
        except OSError:
            pass
    print("Reset broken incremental chain:", slug)
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
        "level": meta.get("level"),
        "base": meta.get("base"),
        "chain": meta.get("chain"),
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
        "level": meta.get("level"),
        "base": meta.get("base"),
        "chain": meta.get("chain"),
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
                "level": meta.get("level"),
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

# archive_meta_level META_PATH → "level<TAB>base" ("0<TAB>" for legacy/absent metas)
archive_meta_level() {
    python3 -c '
import json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception:
    m = {}
print("%s\t%s" % (m.get("level", 0), m.get("base", "")))
' "$1"
}

# fetch_archive NAME → prints a readable local path (remote archives are
# downloaded into RESTORE_TMPD, created by cmd_restore, removed by cleanup)
fetch_archive() {
    local n="$1" a
    a=$(archive_path "$n")
    if [ -f "$a" ]; then
        echo "$a"
        return
    fi
    if meta_is_remote "$a.meta"; then
        s3_configured || die "archive is stored on S3 but S3 is not configured: $n"
        command -v aws >/dev/null || die "aws CLI is not installed"
        echo "Downloading from S3: $n …" >&2
        s3_run s3 cp "s3://$(s3_cfg bucket)/$(s3_key "$n")" "$RESTORE_TMPD/$n" --only-show-errors \
            || die "download from S3 failed: $n"
        echo "$RESTORE_TMPD/$n"
        return
    fi
    die "archive not found: $a"
}

cmd_restore() {
    local name="${1:-}" target="${2:-/}"
    [ -n "$name" ] || die "usage: restore ARCHIVE [TARGET]"
    archive_path "$name" >/dev/null   # validates the name before anything runs

    case "$target" in
        /*) ;;
        *) die "target must be an absolute path" ;;
    esac
    mkdir -p "$target"

    # Resolve the chain bottom-up: an incremental is restored by extracting its
    # full and every intermediate member in order (metas link via "base")
    local -a members=()
    local cur="$name" info lvl base
    while :; do
        members=("$cur" ${members[@]+"${members[@]}"})
        [ "${#members[@]}" -le 400 ] || die "backup chain too long or corrupted"
        info=$(archive_meta_level "$DEST/$cur.meta")
        IFS=$'\t' read -r lvl base <<< "$info"
        [ "$lvl" = "1" ] || break
        [ -n "$base" ] || die "incremental archive has no recorded base: $cur"
        cur="$base"
    done

    RESTORE_TMPD=$(mktemp -d)
    local n path
    if [ "${#members[@]}" -eq 1 ]; then
        # Plain archive: extract as before — files created after the backup
        # are left untouched
        path=$(fetch_archive "$name")
        echo "Restoring $name to $target …"
        tar -xzf "$path" -C "$target"
    else
        # Chain restore: --listed-incremental=/dev/null replays each member's
        # dumpdirs, so deletions recorded along the chain propagate and the
        # target ends up exactly as the folder was at the chosen archive
        echo "Incremental archive: restoring its chain of ${#members[@]} backups …"
        for n in "${members[@]}"; do
            path=$(fetch_archive "$n")
            echo "Restoring $n to $target …"
            tar -xzf "$path" -C "$target" --listed-incremental=/dev/null
            [ "$path" = "$DEST/$n" ] || rm -f "$path"
        done
    fi
    rm -rf "$RESTORE_TMPD"
    RESTORE_TMPD=""
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

    # Chain guard: an archive other backups build on (an incremental's base or
    # a chain's full) cannot go while its dependents are still restorable
    local deps
    deps=$(python3 - "$DEST" "$name" <<'EOF'
import json, os, glob, sys
dest, target = sys.argv[1], sys.argv[2]
n = 0
for mp in glob.glob(os.path.join(dest, "backup-*.tar.gz.meta")):
    try:
        meta = json.load(open(mp))
    except Exception:
        continue
    if os.path.basename(mp)[:-5] == target:
        continue
    if meta.get("base") == target or meta.get("chain") == target:
        n += 1
print(n)
EOF
)
    if [ "$deps" -gt 0 ]; then
        die "$deps incremental backup(s) depend on this archive: delete those first (newest first)"
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

    # If this was the tip (or the full) of the active chain, the snapshot no
    # longer matches any existing archive: reset the chain so the folder's
    # next run starts a fresh full
    python3 - "$DEST" "$name" <<'EOF'
import json, os, glob, sys
dest, target = sys.argv[1], sys.argv[2]
snar_dir = os.path.join(dest, ".snar")
for cp in glob.glob(os.path.join(snar_dir, "*.chain")):
    try:
        c = json.load(open(cp))
    except Exception:
        continue
    if target in (c.get("prev"), c.get("full")):
        slug = os.path.basename(cp)[:-6]
        for f in (cp, os.path.join(snar_dir, slug + ".snar")):
            try:
                os.remove(f)
            except OSError:
                pass
EOF
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
