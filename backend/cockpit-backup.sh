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
    [ -n "$CLEANUP_PROGRESS_SLUG" ] && progress_clear "$CLEANUP_PROGRESS_SLUG"
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
PROGRESS_DIR="$DEST/.progress"

# Parallel (de)compression when pigz is installed: plain gzip is single-threaded
# and dominates archive/synthetic build times on multi-core boards (a Pi 5 has
# 4 cores — pigz cuts compression time roughly 4×). Output stays gzip-compatible.
if command -v pigz >/dev/null 2>&1; then GZ_C=pigz; GZ_D="pigz -dc"; else GZ_C=gzip; GZ_D="gzip -dc"; fi

# ---------- tar byte-counter progress ----------
# tar's --checkpoint output proved unreliable to capture across environments, so
# progress is measured with an inline byte counter piped between tar and gzip
# (backup) or gzip and tar (restore). It counts the uncompressed stream, so it is
# independent of the tar flavor/version. The parser lives in a temp file so
# python's stdin stays the data pipe (a heredoc program would consume it).
stream_counter_py() {   # stream_counter_py PATH — (re)write the counter script
    local rd="$1"
    mkdir -p "$(dirname "$rd")"
    cat > "$rd" <<'PYEOF'
import sys, os, json, time
try:
    import signal
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except Exception:
    pass
mode = sys.argv[1]                       # 'file' (backup) or 'emit' (restore)
den = int(sys.argv[2] or 0)
start = float(sys.argv[3] or 0)
inp, out = sys.stdin.buffer, sys.stdout.buffer
total = 0
last = 0.0
def write_file(pct, eta, detail):
    progf, folder, step, steps = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
    try:
        tmp = progf + '.tmp'
        json.dump({"folder": folder, "phase": "archive", "step": int(step), "steps": int(steps),
                   "pct": pct, "eta": eta, "detail": detail, "ts": int(time.time())}, open(tmp, 'w'))
        os.replace(tmp, progf)
    except Exception:
        pass
def write_emit(pct, eta, detail):
    try:
        obj = {"phase": "extract", "member": int(sys.argv[4]), "members": int(sys.argv[5]),
               "pct": pct, "eta": eta, "detail": detail}
        sys.stderr.write("@@P@@ " + json.dumps(obj) + "\n"); sys.stderr.flush()
    except Exception:
        pass
report = write_file if mode == 'file' else write_emit
try:
    while True:
        chunk = inp.read(1 << 20)
        if not chunk:
            break
        out.write(chunk)
        total += len(chunk)
        now = time.time()
        if now - last >= 1:
            last = now
            if den > 0:
                pct = min(99, int(total * 100 / den))
                el = now - start if now > start else 0.001
                rate = total / el
                eta = int(max(0, (den - total) / rate)) if rate > 0 else None
                report(pct, eta, None)
            else:
                report(None, None, "%d MB" % (total // 1048576))
    out.flush()
except BrokenPipeError:
    pass
PYEOF
}

# ---------- Live progress ----------
# Each running backup writes its current phase/percentage to
# $PROGRESS_DIR/<slug>.json; `list` reads it so the UI shows spinner + phase +
# "step N of M" + percentage + ETA, and it survives page reloads.
# P_STEP / P_STEPS are set per run (total phases: backup, +scan if incremental,
# +upload if S3).
P_STEP=1
P_STEPS=1
P_FOLDER=""
CLEANUP_PROGRESS_SLUG=""

progress_set() {   # progress_set SLUG PHASE PCT ETA DETAIL   (pct/eta empty → null)
    mkdir -p "$PROGRESS_DIR"
    local pct="${3:-}" eta="${4:-}" detail="${5:-}"
    [ -n "$pct" ] || pct=null
    [ -n "$eta" ] || eta=null
    if [ -n "$detail" ]; then detail="\"$detail\""; else detail=null; fi
    printf '{"folder":"%s","phase":"%s","step":%s,"steps":%s,"pct":%s,"eta":%s,"detail":%s,"ts":%s}' \
        "$P_FOLDER" "$2" "${P_STEP:-1}" "${P_STEPS:-1}" "$pct" "$eta" "$detail" "$(date +%s)" \
        > "$PROGRESS_DIR/$1.json.tmp" 2>/dev/null && \
        mv -f "$PROGRESS_DIR/$1.json.tmp" "$PROGRESS_DIR/$1.json" 2>/dev/null || true
}

progress_clear() { rm -f "$PROGRESS_DIR/$1.json" "$PROGRESS_DIR/$1.json.tmp" 2>/dev/null || true; }

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

# measure_folder FOLDER SINCE_TS BASELINE SLUG MODE(scan|measure) → "DEN FILECOUNT"
# Walks the folder honoring the same excludes as the backup. In "scan" mode it
# also streams scan progress (pct from the previous run's file count) and DEN is
# the changed bytes (mtime > SINCE_TS); in "measure" mode DEN is the total bytes.
measure_folder() {
    local folder="$1" since="$2" baseline="$3" mslug="$4" mode="$5"
    local -a exc=()
    local e
    while IFS= read -r e; do [ -n "$e" ] && exc+=("$e"); done < <(cfg_excludes "$folder")
    # Excludes are passed as ARGS (not stdin): the heredoc IS python's stdin.
    python3 - "$folder" "$since" "$baseline" "$PROGRESS_DIR/$mslug.json" "$mode" \
        "${P_STEP:-1}" "${P_STEPS:-1}" "$folder" ${exc[@]+"${exc[@]}"} <<'PYEOF'
import os, sys, time, fnmatch, json
folder = sys.argv[1].rstrip('/') or '/'
since = float(sys.argv[2] or 0)
baseline = int(sys.argv[3] or 0)
progf, mode, step, steps, folder_full = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
patterns = []
for p in sys.argv[9:]:
    p = p.strip()
    if not p:
        continue
    if p.startswith('/'):
        if p == folder or p.startswith(folder + '/'):
            p = p[len(folder) + 1:]
        else:
            continue
    patterns.append(p.rstrip('/'))
def excluded(rel, name):
    return any(fnmatch.fnmatch(rel, q) or fnmatch.fnmatch(name, q) for q in patterns)
def write_prog(pct, eta, detail):
    try:
        tmp = progf + '.tmp'
        json.dump({"folder": folder_full, "phase": "scan", "step": int(step), "steps": int(steps),
                   "pct": pct, "eta": eta, "detail": detail, "ts": int(time.time())},
                  open(tmp, 'w'))
        os.replace(tmp, progf)
    except Exception:
        pass
total = changed = count = 0
start = time.time(); last = 0.0
for root, dirs, names in os.walk(folder):
    rr = os.path.relpath(root, folder)
    def rel(n):
        return n if rr == '.' else rr + '/' + n
    dirs[:] = [d for d in dirs if not excluded(rel(d), d)]
    for n in names:
        if excluded(rel(n), n):
            continue
        try:
            st = os.lstat(os.path.join(root, n))
        except OSError:
            continue
        count += 1
        total += st.st_size
        if st.st_mtime > since:
            changed += st.st_size
        if mode == 'scan':
            now = time.time()
            if now - last >= 0.5:
                last = now
                pct = eta = None
                if baseline > 0:
                    pct = min(99, int(count * 100 / baseline))
                    el = max(0.001, now - start); rate = count / el
                    if rate > 0:
                        eta = int(max(0, (baseline - count) / rate))
                write_prog(pct, eta, "%d files" % count)
print("%d %d" % (changed if mode == 'scan' else total, count))
PYEOF
}

# upload_progress SLUG START_TS  — reads `aws s3 cp` progress on stdin, writes
# the upload phase percentage/ETA, and forwards non-progress lines to stderr.
# The parser lives in a temp file so python's stdin stays the aws pipe (a
# heredoc program would otherwise consume stdin).
upload_progress() {
    mkdir -p "$PROGRESS_DIR"
    local rd="$PROGRESS_DIR/.upreader.py"
    # Rewrite every run: this file persists in the destination between runs, so a
    # guard would keep an older parser version around after an upgrade.
    cat > "$rd" <<'PYEOF'
import sys, re, json, time, os
progf, start, step, steps, folder = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
units = {"Bytes": 1, "B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4,
         "KB": 1000, "MB": 1000**2, "GB": 1000**3}
pat = re.compile(r"Completed\s+([\d.]+)\s+(\w+)/~?\s*([\d.]+)\s+(\w+)")
last = 0.0
fd = sys.stdin.fileno()
buf = b""
# aws s3 cp refreshes the progress line with '\r' (no newline until the end), so
# read raw bytes as they arrive and split on both '\r' and '\n' to see each update.
while True:
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    parts = re.split(rb"[\r\n]", buf)
    buf = parts.pop()
    for raw in parts:
        seg = raw.decode("utf-8", "replace")
        m = pat.search(seg)
        if not m:
            if seg.strip():
                sys.stderr.write(seg + "\n")
            continue
        done = float(m.group(1)) * units.get(m.group(2), 1)
        total = float(m.group(3)) * units.get(m.group(4), 1)
        now = time.time()
        if now - last < 1:
            continue
        last = now
        pct = min(99, int(done * 100 / total)) if total > 0 else None
        el = max(0.001, now - start); rate = done / el
        eta = int(max(0, (total - done) / rate)) if rate > 0 else None
        try:
            tmp = progf + '.tmp'
            json.dump({"folder": folder, "phase": "upload", "step": int(step), "steps": int(steps),
                       "pct": pct, "eta": eta, "detail": None, "ts": int(now)}, open(tmp, 'w'))
            os.replace(tmp, progf)
        except Exception:
            pass
PYEOF
    python3 "$rd" "$PROGRESS_DIR/$1.json" "$2" "${P_STEP:-1}" "${P_STEPS:-1}" "$P_FOLDER"
}

backup_one() {
    local folder="$1" stamp="$2" trigger="${3:-manual}"
    local slug name archive tmp workdir rel start_ts remote
    slug=$(slug_of "$folder")
    rel="${folder#/}"
    P_FOLDER="$folder"

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
    CLEANUP_PROGRESS_SLUG="$slug"

    # Phase plan for the progress UI: [scan?] → backup → [upload?]
    local is_scan=false
    if $incremental && [ "$level" = "1" ]; then is_scan=true; fi
    P_STEPS=1
    $is_scan && P_STEPS=$((P_STEPS + 1))
    [ "$remote" = "true" ] && P_STEPS=$((P_STEPS + 1))
    local backup_step=1
    $is_scan && backup_step=2

    # ---- Measure / scan → denominator (bytes tar will archive) -----------
    local den=0 filecount=0 since_ts=0 baseline=0
    if $is_scan; then
        P_STEP=1
        since_ts="$chain_started"
        [ -f "$SNAR_DIR/$slug.count" ] && baseline=$(cat "$SNAR_DIR/$slug.count" 2>/dev/null || echo 0)
        progress_set "$slug" scan "" "" "scanning…"
        read -r den filecount < <(measure_folder "$folder" "$since_ts" "$baseline" "$slug" scan)
    else
        read -r den filecount < <(measure_folder "$folder" 0 0 "$slug" measure)
    fi
    case "$den" in ''|*[!0-9]*) den=0 ;; esac
    if $incremental && [ -n "$filecount" ]; then
        echo "$filecount" > "$SNAR_DIR/$slug.count" 2>/dev/null || true
    fi
    # Record the uncompressed size in the (running) meta so a later restore can
    # show an extract percentage. Old archives simply won't have it.
    python3 - "$workdir/$name.meta" "$den" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    d["usize"] = int(sys.argv[2])
    json.dump(d, open(sys.argv[1], "w"))
except Exception:
    pass
PYEOF

    # ---- Archive: tar → byte counter → gzip (progress from the counter) ---
    P_STEP="$backup_step"
    local archive_start; archive_start=$(date +%s)
    progress_set "$slug" archive 0 "" ""
    local cpy="$PROGRESS_DIR/.counter.py"; stream_counter_py "$cpy"
    tar -cf - ${tar_args[@]+"${tar_args[@]}"} -C / "$rel" \
            2> >(grep -v 'Removing leading' >&2 || true) \
        | python3 "$cpy" file "$den" "$archive_start" \
            "$PROGRESS_DIR/$slug.json" "$P_FOLDER" "${P_STEP:-1}" "${P_STEPS:-1}" \
        | $GZ_C > "$tmp"

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
        P_STEP="$P_STEPS"   # upload is always the last phase
        progress_set "$slug" upload 0 "" ""
        if s3_run s3 cp "$tmp" "s3://$bucket/$key" > >(upload_progress "$slug" "$up_start") 2>&1; then
            # Meta stub in the destination keeps the remote archive visible in the UI
            python3 - "$archive.meta" "$folder" "$trigger" "$size_b" "$meta_level" "$meta_chain" "$meta_base" "$den" <<'EOF'
import json, sys, time
meta = {"folder": sys.argv[2], "trigger": sys.argv[3],
        "remote": True, "s3": True,
        "size": int(sys.argv[4]), "mtime": int(time.time()),
        "usize": int(sys.argv[8])}
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

    progress_clear "$slug"
    CLEANUP_PROGRESS_SLUG=""
}

prune() {
    # Remove backups older than each folder's retention (global default for the rest)
    echo "Pruning old backups…"
    # Drop progress files left by a hard-killed run (normal runs clear their own)
    find "$PROGRESS_DIR" -maxdepth 1 -name '*.json*' -mmin +60 -delete 2>/dev/null || true
    local out
    out=$(python3 - "$CONFIG" "$DEST" "$RETENTION" <<'EOF'
import json, os, glob, sys, time

cfg = json.load(open(sys.argv[1]))
dest, default_ret = sys.argv[2], int(sys.argv[3])
retentions = {b["folder"]: int(b.get("retention_days", default_ret))
              for b in cfg.get("backups", [])}
# Tiered (GFS) retention policies, e.g. keep 2/day for 7 days, then 1/week for
# 4 weeks, then 1/month for 12 months. Folders without one keep the flat rule.
# Two shapes: legacy dict {daily:{keep,days},…} and the list form
# [{keep, per, span}, …] with per ∈ hour|day|week|month|year.
policies = {b["folder"]: b["retention"] for b in cfg.get("backups", [])
            if isinstance(b.get("retention"), (dict, list))}
# Folders whose finished chains are consolidated per retention point-by-point:
# prune must leave their multi-member chains alone (a chain dated by its newest
# member could lose its bucket to a newer chain and be dropped whole, before
# consolidation could materialize the points the policy wants to keep).
consolidated_folders = {b["folder"] for b in cfg.get("backups", [])
                        if b.get("mode") == "incremental" and b.get("consolidate")}
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

# Retention works per chain: a chain (full + its incrementals) is one unit and
# expires only as a whole, dated by its NEWEST member — a full must never be
# pruned out from under incrementals that still need it. Archives without a
# chain (classic full mode, legacy) are units of one.
#
# Flat rule (retention_days): the unit expires once older than N days.
# Tiered rule (retention policy): a list of independent, OVERLAPPING rules
# (keep, unit, span), restic-style. Each rule looks back span×unit from now
# and keeps the newest `keep` units per calendar bucket of `unit` (hour, day,
# ISO week, month, year) inside that window. A unit survives if ANY rule
# selects it; anything older than every window is dropped. The newest unit
# of a folder is always kept as a safety net. Remote members are printed as
# "RemoteExpired:" for the shell to delete on S3.
import datetime as _dt

UNIT_SECONDS = {"hour": 3600, "day": 86400, "week": 7 * 86400,
                "month": 30 * 86400, "year": 365 * 86400}
UNIT_ORDER = {"hour": 0, "day": 1, "week": 2, "month": 3, "year": 4}

def norm_policy(pol):
    # Either shape → canonical [(keep, unit, span), …]; malformed tiers dropped
    tiers = []
    if isinstance(pol, dict):
        for k, unit, span_key in (("daily", "day", "days"),
                                  ("weekly", "week", "weeks"),
                                  ("monthly", "month", "months"),
                                  ("yearly", "year", "years")):
            t = pol.get(k) or {}
            try:
                keep, span = int(t.get("keep", 0)), int(t.get(span_key, 0))
            except (TypeError, ValueError):
                continue
            if keep > 0 and span > 0:
                tiers.append((keep, unit, span))
    elif isinstance(pol, list):
        for t in pol:
            if not isinstance(t, dict):
                continue
            try:
                keep, span = int(t.get("keep", 0)), int(t.get("span", 0))
            except (TypeError, ValueError):
                continue
            unit = t.get("per")
            if unit in UNIT_SECONDS and keep > 0 and span > 0:
                tiers.append((keep, unit, span))
    tiers.sort(key=lambda t: (UNIT_ORDER[t[1]], -t[0]))
    return tiers

def bucket_id(unit, t):
    if unit == "hour":
        return (t.date().isoformat(), t.hour)
    if unit == "day":
        return t.date().isoformat()
    if unit == "week":
        iso = t.isocalendar()
        return (iso[0], iso[1])
    if unit == "month":
        return (t.year, t.month)
    return t.year

def gfs_keep(units, pol):
    tiers = norm_policy(pol)
    kept = set()
    ordered = sorted(units, reverse=True)                # newest first
    for keep, unit, span in tiers:
        window = span * UNIT_SECONDS[unit]
        counts = {}
        for newest_ts, key in ordered:
            if now - newest_ts <= window:
                bucket = bucket_id(unit, _dt.datetime.fromtimestamp(newest_ts))
                if counts.get(bucket, 0) < keep:
                    counts[bucket] = counts.get(bucket, 0) + 1
                    kept.add(key)
    return kept

groups = {}
for name, e in entries.items():
    groups.setdefault(e["chain"] or name, []).append(name)

units_by_folder = {}
for key, members in groups.items():
    folder = next((entries[n]["folder"] for n in members if entries[n]["folder"]), None)
    if folder in consolidated_folders and len(members) > 1:
        continue   # chains of consolidate-enabled folders belong to consolidation
    newest = max(entries[n]["mtime"] for n in members)
    units_by_folder.setdefault(folder, []).append((newest, key))

expired_keys = set()
for folder, units in units_by_folder.items():
    pol = policies.get(folder)
    if pol:
        kept = gfs_keep(units, pol)
    else:
        ret = retentions.get(folder, default_ret)
        kept = {key for newest, key in units if now - newest <= ret * 86400}
    kept.add(max(units)[1])   # never drop a folder's most recent backup
    expired_keys.update(key for _, key in units if key not in kept)

for key in expired_keys:
    for n in groups[key]:
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
    cmd_consolidate
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

def entry_times(b):
    # "every_minutes": M sub-hour runs (any divisor of 60), e.g. 30 → :00, :30
    try:
        m = int(b.get("every_minutes", 0))
    except (TypeError, ValueError):
        m = 0
    if 1 <= m < 60 and 60 % m == 0:
        return [(h, mi) for h in range(24) for mi in range(0, 60, m)]
    # "every_hours": N runs at 00:00, 0N:00, … — alternative to times[]
    try:
        n = int(b.get("every_hours", 0))
    except (TypeError, ValueError):
        n = 0
    if 1 <= n <= 24:
        return [(h, 0) for h in range(0, 24, n)]
    ts = b.get("times") or [b.get("time") or default_time]
    parsed = []
    for t in ts:
        try:
            hh, mm = map(int, str(t).split(":"))
            parsed.append((hh, mm))
        except (ValueError, AttributeError):
            pass
    return parsed or [(2, 0)]

for b in cfg.get("backups", []):
    if not b.get("enabled", True):
        continue
    # Last passed occurrence across ALL of the entry's daily times
    scheds = []
    for hh, mm in entry_times(b):
        s = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
        if now < s:
            s -= datetime.timedelta(days=1)
        scheds.append(s)
    sched = max(scheds)
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

    [ "$count" -eq 0 ] || { prune; cmd_consolidate; }
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
    # "every_minutes": M sub-hour runs (any divisor of 60), e.g. 30 → :00, :30
    try:
        m = int(b.get("every_minutes", 0))
    except (TypeError, ValueError):
        m = 0
    if 1 <= m < 60 and 60 % m == 0:
        for h in range(24):
            for mi in range(0, 60, m):
                times.add("%02d:%02d" % (h, mi))
        continue
    # "every_hours": N runs at 00:00, 0N:00, … — alternative to times[]
    try:
        n = int(b.get("every_hours", 0))
    except (TypeError, ValueError):
        n = 0
    if 1 <= n <= 24:
        for h in range(0, 24, n):
            times.add("%02d:00" % h)
        continue
    for t in (b.get("times") or [b.get("time") or default]):
        try:
            hh, mm = str(t).split(":")
            times.add("%02d:%02d" % (int(hh), int(mm)))
        except (ValueError, AttributeError):
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
    # Housekeeping: drop Download-cache entries (fetched S3 copies, combined
    # delta archives, leftover build dirs) once stale, plus consolidate/restore
    # work dirs orphaned by a hard kill (generous age: they can run long)
    find "$FETCH_DIR" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null || true
    find "$FETCH_DIR" -maxdepth 1 -name '.build.*' -type d -mmin +60 -exec rm -rf {} + 2>/dev/null || true
    find "$REMOTE_TMP" -maxdepth 1 \( -name '.consolidate.*' -o -name '.restore.*' \) -type d -mmin +720 -exec rm -rf {} + 2>/dev/null || true
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
        "consolidated": bool(meta.get("consolidated")),
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
        "consolidated": bool(meta.get("consolidated")),
    })

archives.sort(key=lambda x: x["mtime"], reverse=True)

# In-progress backups. Keyed by folder so the scan phase (which has a progress
# file but no .partial yet) and the archive/upload phases all merge into one
# entry. Base info comes from the .partial+.meta marker; live phase/percentage
# comes from the .progress/<slug>.json file (fresh ts = still running).
import time as _time
now_ts = _time.time()
running_map = {}
for pat in ("backup-*.tar.gz.partial", os.path.join(".tmp", "backup-*.tar.gz.partial")):
    for p in glob.glob(os.path.join(dest, pat)):
        meta = read_meta(p[:-8] + ".meta")
        f = meta.get("folder")
        if f:
            running_map[f] = {"folder": f, "trigger": meta.get("trigger"),
                              "remote": bool(meta.get("s3")), "level": meta.get("level")}
for pf in glob.glob(os.path.join(dest, ".progress", "*.json")):
    pr = read_meta(pf)
    f = pr.get("folder")
    if not f or now_ts - pr.get("ts", 0) > 120:   # stale (crashed) → ignore
        continue
    ent = running_map.get(f, {"folder": f})
    ent.update({"phase": pr.get("phase"), "step": pr.get("step"), "steps": pr.get("steps"),
                "pct": pr.get("pct"), "eta": pr.get("eta"), "detail": pr.get("detail")})
    running_map[f] = ent
running = list(running_map.values())

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

# The restore streams progress to stdout as "@@P@@ {json}" lines that the UI
# parses (phase, member N of M, pct, eta); everything else is console output.
restore_emit() {   # phase member members pct eta detail
    local pct="${4:-}" eta="${5:-}" detail="${6:-}"
    [ -n "$pct" ] || pct=null
    [ -n "$eta" ] || eta=null
    if [ -n "$detail" ]; then detail="\"$detail\""; else detail=null; fi
    printf '@@P@@ {"phase":"%s","member":%s,"members":%s,"pct":%s,"eta":%s,"detail":%s}\n' \
        "$1" "$2" "$3" "$pct" "$eta" "$detail"
}

# Uncompressed size recorded in a backup meta (0 when absent, e.g. old archives)
archive_meta_usize() {
    python3 -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("usize",0)))
except Exception:
    print(0)' "$1"
}

# aws download reader: emits download progress as @@P@@ lines. Lives in a temp
# file so python's stdin stays the aws pipe.
restore_dl_reader() {   # member members start
    local rd="$RESTORE_TMPD/.dlreader.py"
    if [ ! -f "$rd" ]; then
        cat > "$rd" <<'PYEOF'
import sys, re, json, time, os
member, members, start = sys.argv[1], sys.argv[2], float(sys.argv[3])
units = {"Bytes":1,"B":1,"KiB":1024,"MiB":1024**2,"GiB":1024**3,"TiB":1024**4,"KB":1000,"MB":1000**2,"GB":1000**3}
pat = re.compile(r"Completed\s+([\d.]+)\s+(\w+)/~?\s*([\d.]+)\s+(\w+)")
last = 0.0
fd = sys.stdin.fileno()
buf = b""
# aws refreshes the progress line with '\r'; read raw bytes and split on both.
while True:
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    parts = re.split(rb"[\r\n]", buf)
    buf = parts.pop()
    for raw in parts:
        seg = raw.decode("utf-8", "replace")
        m = pat.search(seg)
        if not m:
            if seg.strip():
                sys.stderr.write(seg + "\n")
            continue
        done = float(m.group(1)) * units.get(m.group(2), 1)
        total = float(m.group(3)) * units.get(m.group(4), 1)
        now = time.time()
        if now - last < 1:
            continue
        last = now
        pct = min(99, int(done * 100 / total)) if total > 0 else None
        el = max(0.001, now - start); rate = done / el
        eta = int(max(0, (total - done) / rate)) if rate > 0 else None
        obj = {"phase": "download", "member": int(member), "members": int(members),
               "pct": pct, "eta": eta, "detail": None}
        sys.stdout.write("@@P@@ " + json.dumps(obj) + "\n"); sys.stdout.flush()
PYEOF
    fi
    python3 "$rd" "$1" "$2" "$3"
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

    # Destination disk, not /tmp: downloading a large S3 member into a tmpfs
    # /tmp can run out of space
    mkdir -p "$REMOTE_TMP"
    RESTORE_TMPD=$(mktemp -d "$REMOTE_TMP/.restore.XXXXXX")
    local M=${#members[@]} idx=0 n a src usize
    [ "$M" -gt 1 ] && echo "Incremental archive: restoring its chain of $M backups …"
    exec 4>&1   # save restore stdout so the byte counter can emit @@P@@ progress to it
    for n in "${members[@]}"; do
        idx=$((idx + 1))
        a=$(archive_path "$n")
        # Obtain the archive locally (download remote members with progress)
        if [ -f "$a" ]; then
            src="$a"
        elif meta_is_remote "$a.meta"; then
            s3_configured || die "archive is stored on S3 but S3 is not configured: $n"
            command -v aws >/dev/null || die "aws CLI is not installed"
            src="$RESTORE_TMPD/$n"
            echo "Downloading from S3: $n …"
            restore_emit download "$idx" "$M" 0 "" ""
            s3_run s3 cp "s3://$(s3_cfg bucket)/$(s3_key "$n")" "$src" \
                > >(restore_dl_reader "$idx" "$M" "$(date +%s)") 2>&1 \
                || die "download from S3 failed: $n"
        else
            die "archive not found: $a"
        fi

        # Extract with progress from the inline byte counter (uncompressed size
        # known → percentage; unknown → MB processed)
        usize=$(archive_meta_usize "$a.meta")
        echo "Restoring $n to $target …"
        local RDEN=${usize:-0}
        restore_emit extract "$idx" "$M" 0 "" ""
        local cpy="$RESTORE_TMPD/.counter.py"; stream_counter_py "$cpy"
        local -a xargs=(-xf - -C "$target")
        [ "$M" -gt 1 ] && xargs+=(--listed-incremental=/dev/null)
        # gzip → byte counter (emits @@P@@ progress on fd 4 = restore stdout) → tar
        if ! $GZ_D "$src" \
            | python3 "$cpy" emit "$RDEN" "$(date +%s)" "$idx" "$M" 2>&4 \
            | tar "${xargs[@]}" 2> >(grep -v 'Removing leading' >&2 || true); then
            # GNU tar's rename replay can trip over rotated directories —
            # extract_member repairs and retries (no byte progress meanwhile)
            restore_emit extract "$idx" "$M" "" "" "repairing directory renames…"
            local empc=""; [ "$idx" -gt 1 ] || empc="nopreclean"
            extract_member "$src" "$target" $empc || die "extracting $n failed"
        fi
        [ "$src" = "$DEST/$n" ] || rm -f "$src"
    done
    exec 4>&-
    rm -rf "$RESTORE_TMPD"
    RESTORE_TMPD=""
    restore_emit done "$M" "$M" 100 0 ""
    echo "Restore completed."
}

# Extract one chain member into WORK, repairing GNU tar's fragile rename
# replay. Apps that rotate directories (plex bundles, radarr MediaCover:
# rm B; mv A B) make tar record a rename it then cannot replay — "Cannot
# rename 'A' to 'B': Directory not empty" — because the stale target still
# exists in the tree.
#
# The repair must happen BEFORE extraction, in one pass: re-running a member
# after a partial replay is NOT idempotent (renames already performed fail
# differently on the rerun, and two conflicting renames alternate forever).
# So the member's recorded renames (R/T pairs in its GNU dumpdirs) are parsed
# up front and every stale target is cleared, then tar runs once. Targets that
# are themselves rename sources (swap chains) are left to tar's own temp-name
# mechanism, which replays them fine.
extract_member() {   # SRC WORKDIR [nopreclean]
    local src="$1" work="$2" tries=0 errf to cleared=""
    # Full (level-0) members carry no rename records — callers pass "nopreclean"
    # to skip the parse pass and its extra decompression of the biggest file.
    if [ "${3:-}" != "nopreclean" ]; then
    python3 - "$src" "$work" <<'PY' || true
import os, shutil, sys, tarfile
src, work = sys.argv[1], sys.argv[2]
pairs = []
try:
    tf = tarfile.open(src, "r:gz")
    for m in tf:
        # GNU dumpdir typeflag is 'D' (tarfile has no named constant for it)
        if m.type != b"D" or m.size <= 0 or m.size > (50 << 20):
            continue
        tf.fileobj.seek(m.offset_data)
        data = tf.fileobj.read(m.size)
        prev = None
        for ent in data.split(b"\0"):
            if not ent:
                continue
            c, val = ent[:1], ent[1:].decode("utf-8", "replace")
            if c == b"R":
                prev = val
            elif c == b"T" and prev is not None:
                pairs.append((prev, val))
                prev = None
            else:
                prev = None
    tf.close()
except Exception:
    pass
sources = {f for f, t in pairs}
workreal = os.path.realpath(work)
for f, t in pairs:
    if not t or t.startswith("/") or ".." in t.split("/"):
        continue
    if t in sources:      # swap/chain: tar's temp-name replay handles it
        continue
    tgt = os.path.join(work, t)
    if os.path.isdir(tgt) and not os.path.islink(tgt) \
       and os.path.exists(os.path.join(work, f)) \
       and os.path.realpath(os.path.dirname(tgt)).startswith(workreal):
        try:
            shutil.rmtree(tgt)
            sys.stderr.write("note: cleared stale rename target '%s'\n" % t)
        except OSError:
            pass
PY
    fi
    errf=$(mktemp) || return 1
    while :; do
        if $GZ_D "$src" | LC_ALL=C tar -xf - -C "$work" --listed-incremental=/dev/null 2> "$errf"; then
            grep -v 'Removing leading' "$errf" >&2 || true
            rm -f "$errf"
            return 0
        fi
        # Last-resort single-shot repairs for anything the pre-clean missed;
        # a target seen twice means we're not converging — stop.
        tries=$((tries + 1))
        [ "$tries" -le 5 ] || break
        to=$(python3 - "$errf" <<'PY' || true
import re, sys
for line in open(sys.argv[1], errors="replace"):
    if "annot rename" in line:
        q = re.findall(r"['\"‘’]([^'\"‘’]+)['\"‘’]", line)
        if len(q) >= 2:
            print(q[1])
            break
PY
)
        case "$to" in ''|/*|*..*) break ;; esac
        case " $cleared " in *" $to "*) break ;; esac
        [ -d "$work/$to" ] || break
        cleared="$cleared $to"
        echo "note: clearing stale directory '$to' left by a recorded rename, retrying" >&2
        rm -rf "$work/$to"
    done
    # Final fallback. GNU tar CONTINUES extracting after a failed rename replay
    # and only flags the exit status at the end — the member's content is in
    # place except for rotated cache dirs (plex/radarr bundles) whose inode
    # reuse made tar record bogus renames no replay can satisfy. When rename
    # replays are the ONLY errors, accept the member with a loud warning
    # instead of failing the whole chain over regenerable caches.
    if grep -q "Cannot rename" "$errf" && \
       ! grep -vE "Cannot rename|Exiting with failure status due to previous errors|Removing leading" "$errf" | grep -q .; then
        local nrn
        nrn=$(grep -c "Cannot rename" "$errf" || true)
        echo "warning: member applied with $nrn unresolved directory rename(s) — rotated cache dirs may be stale at this restore point" >&2
        grep "Cannot rename" "$errf" >&2 || true
        rm -f "$errf"
        return 0
    fi
    grep -v 'Removing leading' "$errf" >&2 || true
    rm -f "$errf"
    return 1
}

# ---------- Download support ----------
# The Download button asks the backend for a locally readable path via `fetch`.
# Full/Baseline archives: the real file (S3 ones are pulled into a cache under
# the destination first, reused while fresh). Deltas: a raw delta alone is just
# that day's changes, so the chain state up to that member is rebuilt and packed
# into a TEMPORARY combined archive in the same cache. Everything in the cache
# is cleaned after an hour by cmd_list's housekeeping.
FETCH_DIR="$DEST/.tmp/fetch"

fetch_raw() {   # NAME → print a locally readable copy of the archive as-is
    local name="$1" archive
    archive=$(archive_path "$name")
    if [ -f "$archive" ]; then
        printf '%s\n' "$archive"
        return 0
    fi
    meta_is_remote "$archive.meta" || die "archive not found: $name"
    s3_configured || die "archive is stored on S3 but S3 is not configured"
    command -v aws >/dev/null || die "aws CLI is not installed"
    mkdir -p "$FETCH_DIR"
    local target="$FETCH_DIR/$name"
    if [ -s "$target" ]; then
        touch "$target" 2>/dev/null || true   # keep a reused copy fresh in the cache
        printf '%s\n' "$target"
        return 0
    fi
    s3_run s3 cp "s3://$(s3_cfg bucket)/$(s3_key "$name")" "$target.part" --only-show-errors \
        || { rm -f "$target.part"; die "download from S3 failed: $name"; }
    mv -f "$target.part" "$target"
    printf '%s\n' "$target"
}

cmd_fetch() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: fetch ARCHIVE"
    archive_path "$name" >/dev/null
    local lvl base
    IFS=$'\t' read -r lvl base <<< "$(archive_meta_level "$DEST/$name.meta")"
    if [ "$lvl" != "1" ]; then
        fetch_raw "$name"
        return 0
    fi

    # Delta: rebuild the combined state of the chain up to this member
    local stem="${name%-incr.tar.gz}"
    [ "$stem" = "$name" ] && stem="${name%.tar.gz}"
    local combined="$FETCH_DIR/$stem-combined.tar.gz"
    if [ -s "$combined" ]; then
        touch "$combined" 2>/dev/null || true
        printf '%s\n' "$combined"
        return 0
    fi

    local -a members=()
    local cur="$name" info l b folder rel
    while :; do
        members=("$cur" ${members[@]+"${members[@]}"})
        [ "${#members[@]}" -le 400 ] || die "backup chain too long or corrupted"
        info=$(archive_meta_level "$DEST/$cur.meta")
        IFS=$'\t' read -r l b <<< "$info"
        [ "$l" = "1" ] || break
        [ -n "$b" ] || die "incremental archive has no recorded base: $cur"
        cur="$b"
    done
    folder=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("folder",""))' "$DEST/$name.meta" 2>/dev/null)
    [ -n "$folder" ] || die "no folder recorded for $name"
    rel="${folder#/}"

    mkdir -p "$FETCH_DIR"
    local work; work=$(mktemp -d "$FETCH_DIR/.build.XXXXXX") || die "cannot create the work dir"
    local m src first=1 pc
    for m in "${members[@]}"; do
        src=$(fetch_raw "$m") || { rm -rf "$work"; die "cannot obtain chain member: $m"; }
        pc=""; [ "$first" = "1" ] && pc="nopreclean"; first=0
        extract_member "$src" "$work" $pc || { rm -rf "$work"; die "extracting $m failed"; }
    done
    [ -e "$work/$rel" ] || { rm -rf "$work"; die "combined tree is empty ($rel)"; }
    tar -cf - -C "$work" "$rel" 2>/dev/null | $GZ_C > "$combined.part" \
        || { rm -rf "$work"; rm -f "$combined.part"; die "building the combined archive failed"; }
    rm -rf "$work"
    gzip -t "$combined.part" 2>/dev/null || { rm -f "$combined.part"; die "combined archive failed the integrity check"; }
    mv -f "$combined.part" "$combined"
    printf '%s\n' "$combined"
}

# ---------- Consolidation: make finished chains obey the retention policy ----------
# Opt-in per folder ("consolidate": true, incremental only). The retention policy
# (every tier: hours/days/weeks/months/years, or the flat day rule) selects which
# RESTORE POINTS to keep — the same GFS algorithm prune uses, applied to single
# archives instead of whole chains. In FINISHED chains (not the folder's active
# one) each kept delta is materialized as a standalone synthetic full dated at its
# original time, and every other member is removed (S3 too). The active chain
# stays granular. Safe: synthetics are built and verified BEFORE anything is
# deleted; any failure rolls back and leaves the chain intact.

write_consolidated_meta() {   # PATH FOLDER REMOTE(true/false) USIZE SIZE NAME MTIME
    python3 - "$@" <<'EOF'
import json, sys
path, folder, remote, usize, size, name, mtime = sys.argv[1:8]
meta = {"folder": folder, "trigger": "consolidate", "level": 0,
        "chain": name, "consolidated": True,
        "usize": int(usize or 0), "mtime": int(mtime or 0)}
if remote == "true":
    meta["remote"] = True; meta["s3"] = True; meta["size"] = int(size or 0)
json.dump(meta, open(path, "w"))
EOF
}

# Per-folder plan: which members of finished chains to KEEP (per the retention
# policy) and which to DROP. One line per member, chains printed contiguously:
#   ACTION <TAB> CHAIN <TAB> LEVEL <TAB> MTIME <TAB> REMOTE(0/1) <TAB> NAME
# Selection runs over ALL of the folder's archives (active chain and standalone
# fulls included, so bucket quotas are counted correctly), but only members of
# finished multi-member chains are emitted — the rest is prune's business.
consolidation_plan() {   # FOLDER ACTIVE_CHAIN
    python3 - "$CONFIG" "$DEST" "$RETENTION" "$1" "$2" <<'EOF'
import json, os, glob, sys, time
import datetime as _dt

cfgp, dest, default_ret, folder, active = sys.argv[1:6]
cfg = json.load(open(cfgp))
entry = next((b for b in cfg.get("backups", []) if b.get("folder") == folder), {})
pol = entry.get("retention") if isinstance(entry.get("retention"), (dict, list)) else None
ret_days = int(entry.get("retention_days", default_ret))
now = time.time()

UNIT_SECONDS = {"hour": 3600, "day": 86400, "week": 7 * 86400,
                "month": 30 * 86400, "year": 365 * 86400}
UNIT_ORDER = {"hour": 0, "day": 1, "week": 2, "month": 3, "year": 4}

def norm_policy(pol):
    tiers = []
    if isinstance(pol, dict):
        for k, unit, span_key in (("daily", "day", "days"),
                                  ("weekly", "week", "weeks"),
                                  ("monthly", "month", "months"),
                                  ("yearly", "year", "years")):
            t = pol.get(k) or {}
            try:
                keep, span = int(t.get("keep", 0)), int(t.get(span_key, 0))
            except (TypeError, ValueError):
                continue
            if keep > 0 and span > 0:
                tiers.append((keep, unit, span))
    elif isinstance(pol, list):
        for t in pol:
            if not isinstance(t, dict):
                continue
            try:
                keep, span = int(t.get("keep", 0)), int(t.get("span", 0))
            except (TypeError, ValueError):
                continue
            unit = t.get("per")
            if unit in UNIT_SECONDS and keep > 0 and span > 0:
                tiers.append((keep, unit, span))
    tiers.sort(key=lambda t: (UNIT_ORDER[t[1]], -t[0]))
    return tiers

def bucket_id(unit, t):
    if unit == "hour":
        return (t.date().isoformat(), t.hour)
    if unit == "day":
        return t.date().isoformat()
    if unit == "week":
        iso = t.isocalendar()
        return (iso[0], iso[1])
    if unit == "month":
        return (t.year, t.month)
    return t.year

points = []   # (mtime, name, chain, level, remote)
for mp in glob.glob(os.path.join(dest, "backup-*.tar.gz.meta")):
    try:
        meta = json.load(open(mp))
    except Exception:
        continue
    if meta.get("folder") != folder:
        continue
    name = os.path.basename(mp)[:-5]
    remote = bool(meta.get("remote"))
    arch = os.path.join(dest, name)
    if not remote and not os.path.exists(arch):
        continue
    mt = meta.get("mtime")
    if mt is None:
        try:
            mt = os.stat(arch).st_mtime
        except OSError:
            mt = now
    points.append((float(mt), name, meta.get("chain") or name,
                   int(meta.get("level", 0) or 0), remote))

units = [(mt, name) for mt, name, chain, level, remote in points]
if pol:
    tiers = norm_policy(pol)
    kept = set()
    ordered = sorted(units, reverse=True)
    for keep, unit, span in tiers:
        window = span * UNIT_SECONDS[unit]
        counts = {}
        for ts, key in ordered:
            if now - ts <= window:
                b = bucket_id(unit, _dt.datetime.fromtimestamp(ts))
                if counts.get(b, 0) < keep:
                    counts[b] = counts.get(b, 0) + 1
                    kept.add(key)
else:
    kept = {name for mt, name in units if now - mt <= ret_days * 86400}
if units:
    kept.add(max(units)[1])   # never drop the folder's most recent point

chains = {}
for mt, name, chain, level, remote in points:
    chains.setdefault(chain, []).append((mt, name, level, remote))
for chain, members in sorted(chains.items()):
    if chain == active or len(members) < 2:
        continue
    for mt, name, level, remote in sorted(members):
        act = "KEEP" if name in kept else "DROP"
        print("%s\t%s\t%d\t%d\t%d\t%s" % (act, chain, level, int(mt),
                                          1 if remote else 0, name))
EOF
}

# Consolidate one finished chain according to its plan lines. Single pass: the
# chain is extracted member by member (incremental semantics); at each KEPT
# delta the current tree is repacked as a synthetic full dated at that member's
# time. Only when every step succeeded are the replaced originals deleted.
consolidate_one_chain() {   # FOLDER CHAIN PLAN_LINE...
    local folder="$1" chain="$2"; shift 2
    local rel="${folder#/}" slug; slug=$(slug_of "$folder")
    local -a order=()
    local line act lvl mt rmt name
    for line in "$@"; do
        IFS=$'\t' read -r act _ lvl mt rmt name <<< "$line"
        order+=("$act|$lvl|$mt|$rmt|$name")
    done
    # Nothing to do when every member is a kept baseline/full already
    local need=false e
    for e in "${order[@]}"; do
        IFS='|' read -r act lvl mt rmt name <<< "$e"
        [ "$act" = "DROP" ] && need=true
        [ "$act" = "KEEP" ] && [ "$lvl" = "1" ] && need=true
    done
    $need || return 0

    echo "Consolidating chain $chain of $folder (retention-selected points) …"
    # Work on the destination disk: /tmp is often a small tmpfs (RAM) and a big
    # chain (downloaded members + extracted tree + synthetic full) won't fit
    mkdir -p "$REMOTE_TMP"
    local tmpd; tmpd=$(mktemp -d "$REMOTE_TMP/.consolidate.XXXXXX") || return 1
    local work="$tmpd/tree"; mkdir -p "$work"

    # Live progress for the UI, same server-side files the backup strip uses —
    # it survives page reloads and clears when the work really ends. A heartbeat
    # keeps the timestamp fresh through long member downloads/uploads (the UI
    # hides entries whose ts goes stale).
    P_FOLDER="$folder"; P_STEP=1; P_STEPS=1
    progress_set "$slug" consolidate 0 "" "preparing"
    ( while sleep 25; do
          python3 - "$PROGRESS_DIR/$slug.json" <<'PY' 2>/dev/null || exit 0
import json, sys, time
try:
    p = sys.argv[1]
    d = json.load(open(p))
    d["ts"] = int(time.time())
    json.dump(d, open(p, "w"))
except Exception:
    raise SystemExit(1)
PY
      done ) & local hb=$!
    consolidate_progress_end() {
        kill "$hb" 2>/dev/null || true
        progress_clear "$slug"
    }

    local total=${#order[@]} idx=0
    local -a made=() replaced=()
    local src ok=true stamp sname synth usize size_b
    for e in "${order[@]}"; do
        IFS='|' read -r act lvl mt rmt name <<< "$e"
        idx=$((idx + 1))
        progress_set "$slug" consolidate $(( (idx - 1) * 100 / total )) "" "member $idx of $total"
        if [ -f "$DEST/$name" ]; then
            src="$DEST/$name"
        elif [ "$rmt" = "1" ]; then
            { s3_configured && command -v aws >/dev/null; } || { ok=false; break; }
            src="$tmpd/$name"
            s3_run s3 cp "s3://$(s3_cfg bucket)/$(s3_key "$name")" "$src" --only-show-errors || { ok=false; break; }
        else
            ok=false; break
        fi
        local pc=""
        [ "$lvl" = "1" ] || pc="nopreclean"
        extract_member "$src" "$work" $pc || { ok=false; break; }
        [ "$src" = "$DEST/$name" ] || rm -f "$src"

        if [ "$act" = "KEEP" ] && [ "$lvl" = "1" ]; then
            stamp=$(printf '%s' "$name" | sed -E 's/^backup-.*-([0-9]{8}-[0-9]{6})-(incr|full)\.tar\.gz$/\1/')
            sname="backup-$slug-$stamp-full.tar.gz"
            synth="$tmpd/$sname"
            tar -cf - -C "$work" "$rel" 2>/dev/null | $GZ_C > "$synth" || { ok=false; break; }
            { gzip -t "$synth" 2>/dev/null && [ -s "$synth" ]; } || { ok=false; break; }
            usize=$(du -sb "$work/$rel" 2>/dev/null | cut -f1)
            case "$usize" in ''|*[!0-9]*) usize=0 ;; esac
            size_b=$(wc -c < "$synth" | tr -d ' ')
            if [ "$rmt" = "1" ]; then
                s3_run s3 cp "$synth" "s3://$(s3_cfg bucket)/$(s3_key "$sname")" --only-show-errors || { ok=false; break; }
                s3_run s3 ls "s3://$(s3_cfg bucket)/$(s3_key "$sname")" >/dev/null 2>&1 || { ok=false; break; }
                write_consolidated_meta "$DEST/$sname.meta" "$folder" true "$usize" "$size_b" "$sname" "$mt"
                rm -f "$synth"
                made+=("$sname|1")
            else
                mv -f "$synth" "$DEST/$sname" || { ok=false; break; }
                write_consolidated_meta "$DEST/$sname.meta" "$folder" false "$usize" "$size_b" "$sname" "$mt"
                touch -d "@$mt" "$DEST/$sname" 2>/dev/null || true
                made+=("$sname|0")
            fi
            replaced+=("$name|$rmt")
        elif [ "$act" = "DROP" ]; then
            replaced+=("$name|$rmt")
        fi
    done

    if ! $ok; then
        consolidate_progress_end
        for e in ${made[@]+"${made[@]}"}; do
            IFS='|' read -r sname rmt <<< "$e"
            [ "$rmt" = "1" ] && s3_delete_remote "$sname"
            rm -f "$DEST/$sname" "$DEST/$sname.meta"
        done
        rm -rf "$tmpd"
        echo "consolidate: chain $chain left intact (a step failed)" >&2
        return 1
    fi
    progress_set "$slug" consolidate 99 "" "finishing"
    rm -rf "$tmpd"
    local cnt=0
    for e in ${replaced[@]+"${replaced[@]}"}; do
        IFS='|' read -r name rmt <<< "$e"
        [ "$rmt" = "1" ] && s3_delete_remote "$name"
        rm -f "$DEST/$name" "$DEST/$name.meta"
        cnt=$((cnt + 1))
    done
    consolidate_progress_end
    echo "Chain consolidated: ${#made[@]} synthetic full(s) kept, $cnt archives removed."
    log_line "$folder" "consolidate" "Chain consolidated per retention: ${#made[@]} synthetic full(s), $cnt archives removed"
}

consolidate_folder() {   # FOLDER ACTIVE_CHAIN
    local folder="$1" active="$2" plan cur="" line chain
    plan=$(consolidation_plan "$folder" "$active") || return 0
    [ -n "$plan" ] || return 0
    local -a lines=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        chain=$(printf '%s' "$line" | cut -f2)
        if [ -n "$cur" ] && [ "$chain" != "$cur" ]; then
            consolidate_one_chain "$folder" "$cur" "${lines[@]}" || echo "consolidate: skipped chain $cur" >&2
            lines=()
        fi
        cur="$chain"
        lines+=("$line")
    done <<< "$plan"
    if [ -n "$cur" ] && [ "${#lines[@]}" -gt 0 ]; then
        consolidate_one_chain "$folder" "$cur" "${lines[@]}" || echo "consolidate: skipped chain $cur" >&2
    fi
}

cmd_consolidate() {   # [FOLDER] — apply retention inside finished chains
    local only="${1:-}" folders folder slug active
    folders=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1])); only = sys.argv[2]
for b in cfg.get("backups", []):
    if only and b.get("folder") != only: continue
    if b.get("mode") == "incremental" and b.get("consolidate"):
        print(b["folder"])
' "$CONFIG" "$only")
    [ -n "$folders" ] || return 0
    mkdir -p "$DEST"
    while IFS= read -r folder; do
        [ -n "$folder" ] || continue
        slug=$(slug_of "$folder")
        active=$(read_chain "$slug" | cut -f1)
        consolidate_folder "$folder" "$active"
    done <<< "$folders"
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

# Let tests source the script for its functions without running a command
[ "${COCKPIT_BACKUP_NO_MAIN:-}" = 1 ] && return 0 2>/dev/null

case "${1:-}" in
    backup)         shift; cmd_backup "${1:-}" ;;
    backup-due)     cmd_backup_due ;;
    apply-schedule) cmd_apply_schedule ;;
    list)           cmd_list ;;
    estimate)       shift; cmd_estimate "$@" ;;
    restore)        shift; cmd_restore "$@" ;;
    delete)         shift; cmd_delete "$@" ;;
    consolidate)    shift; cmd_consolidate "${1:-}" ;;
    fetch)          shift; cmd_fetch "${1:-}" ;;
    test-s3)        cmd_test_s3 ;;
    log)            shift; cmd_log "$@" ;;
    clear-log)      shift; cmd_clear_log "$@" ;;
    *)
        echo "Usage: $0 {backup [FOLDER]|backup-due|apply-schedule|list|estimate FOLDER [PATTERN...]|restore ARCHIVE [TARGET]|delete ARCHIVE|consolidate [FOLDER]|test-s3|log FOLDER|clear-log FOLDER}" >&2
        exit 2
        ;;
esac
