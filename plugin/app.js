/* Cockpit backup plugin — frontend logic
 *
 * Two views, hash-routed:
 *   #/            list of configured backups (add / edit / remove)
 *   #/b/<folder>  detail of one configured backup (archives, backup now, restore)
 *   #/other       archives whose folder is no longer configured
 */
"use strict";

/* ---------- Mock for local preview (outside Cockpit) ---------- */

if (typeof cockpit === "undefined") {
    window.cockpit = (function () {
        let mockConfig = {
            destination: "/var/backups/cockpit-backup",
            retention_days: 30,
            s3: { enabled: true, bucket: "my-backups", region: "eu-south-1", prefix: "srv1/",
                  endpoint: "", access_key: "AKIAEXAMPLE", secret_key: "supersecret" },
            backups: [
                { folder: "/etc", time: "02:00", retention_days: 30, enabled: true, title: "System configuration", s3: true },
                { folder: "/home/roberto/documents", every_hours: 3, enabled: true,
                  retention: [{ keep: 1, per: "hour", span: 24 }, { keep: 6, per: "day", span: 1 },
                              { keep: 1, per: "day", span: 7 }, { keep: 1, per: "week", span: 4 },
                              { keep: 1, per: "month", span: 12 }] },
                { folder: "/var/www", time: "03:00", enabled: false, excludes: ["cache", "*.log"], title: "Web sites", mode: "incremental", full_every: 7,
                  retention: { daily: { keep: 2, days: 7 }, weekly: { keep: 1, weeks: 4 },
                               monthly: { keep: 1, months: 12 }, yearly: { keep: 1, years: 5 } } }
            ]
        };
        const now = Math.floor(Date.now() / 1000);
        const mockArchives = [
            { name: "backup-etc-20260807-020000.tar.gz", size: 12400000, mtime: now - 3600 * 7, folder: "/etc", trigger: "scheduled", remote: true },
            { name: "backup-etc-20260806-020000.tar.gz", size: 12300000, mtime: now - 3600 * 31, folder: "/etc", trigger: "catchup", remote: true },
            { name: "backup-home-roberto-documents-20260807-020000.tar.gz", size: 734003200, mtime: now - 3600 * 7, folder: "/home/roberto/documents", trigger: "scheduled" },
            { name: "backup-home-roberto-documents-20260806-020000.tar.gz", size: 731906048, mtime: now - 3600 * 31, folder: "/home/roberto/documents", trigger: "manual" },
            { name: "backup-home-roberto-documents-20260805-020000.tar.gz", size: 729808896, mtime: now - 3600 * 55, folder: "/home/roberto/documents", trigger: "catchup" },
            { name: "backup-var-www-20260807-030000-incr.tar.gz", size: 12043200, mtime: now - 3600 * 7, folder: "/var/www", trigger: "scheduled", level: 1, base: "backup-var-www-20260806-030000-incr.tar.gz", chain: "backup-var-www-20260805-030000-full.tar.gz" },
            { name: "backup-var-www-20260806-030000-incr.tar.gz", size: 8250000, mtime: now - 3600 * 31, folder: "/var/www", trigger: "scheduled", level: 1, base: "backup-var-www-20260805-030000-full.tar.gz", chain: "backup-var-www-20260805-030000-full.tar.gz" },
            { name: "backup-var-www-20260805-030000-full.tar.gz", size: 220043200, mtime: now - 3600 * 55, folder: "/var/www", trigger: "scheduled", level: 0, chain: "backup-var-www-20260805-030000-full.tar.gz" },
            { name: "backup-20260801-020000.tar.gz", size: 903100000, mtime: now - 3600 * 150, folder: null }
        ];
        const mockRunning = [];
        const mockLogs = {
            "/etc": "2026-08-06 02:00:01 [scheduled] Backup started\n" +
                "2026-08-06 02:00:24 [scheduled] Completed: backup-etc-20260806-020000.tar.gz (12M) in 23s\n" +
                "2026-08-07 02:00:01 [scheduled] Backup started\n" +
                "2026-08-07 02:00:26 [scheduled] Completed: backup-etc-20260807-020000.tar.gz (12M) in 25s\n"
        };
        // For manual testing: simulate a scheduled backup progressing through its
        // phases. opts: { incr: bool, s3: bool } → adds a scan / upload phase.
        window.__simulateScheduled = function (folder, opts) {
            opts = opts || {};
            const phases = [];
            if (opts.incr) phases.push("scan");
            phases.push("archive");
            if (opts.s3) phases.push("upload");
            const steps = phases.length;
            const entry = { folder, trigger: "scheduled", remote: !!opts.s3,
                            phase: phases[0], step: 1, steps, pct: 0, eta: null };
            mockRunning.push(entry);
            let pi = 0, pct = 0;
            const t = setInterval(() => {
                pct += 11;
                if (pct >= 100) {
                    pct = 0; pi++;
                    if (pi >= phases.length) {
                        clearInterval(t);
                        const i = mockRunning.indexOf(entry);
                        if (i !== -1) mockRunning.splice(i, 1);
                        mockArchives.unshift({
                            name: "backup-sim-" + Date.now() + ".tar.gz", size: 5000000,
                            mtime: Math.floor(Date.now() / 1000), folder,
                            trigger: "scheduled", remote: !!opts.s3
                        });
                        return;
                    }
                    entry.phase = phases[pi]; entry.step = pi + 1;
                }
                entry.pct = Math.min(99, pct);
                entry.eta = Math.max(1, Math.round((100 - pct) / 11 * 1.2));
            }, 1000);
        };
        function promiseWith(fns) {
            let streamCb = null;
            const p = new Promise(fns.run ? (res, rej) => fns.run(res, rej, d => streamCb && streamCb(d)) : r => r(fns.out || ""));
            p.stream = cb => { streamCb = cb; return p; };
            p.close = () => {};   // mock: aborting is a no-op
            return p;
        }
        return {
            file: () => ({
                read: () => Promise.resolve(mockConfig),
                replace: c => { mockConfig = c; return Promise.resolve(); }
            }),
            spawn: (args) => {
                const cmd = args.join(" ");
                if (cmd.includes("systemctl show"))
                    return promiseWith({ out: "UnitFileState=enabled\nActiveState=active\nNextElapseUSecRealtime=Fri 2026-08-08 02:00:00 CEST\n" });
                if (args[1] === "list")
                    return promiseWith({ out: JSON.stringify({
                        archives: mockArchives,
                        running: mockRunning,
                        disk: { free: window.__mockDiskFree || 46500000000, total: 250000000000 }
                    }) });
                if (args[1] === "log")
                    return promiseWith({ out: mockLogs[args[2]] || "" });
                if (args[1] === "clear-log") {
                    mockLogs[args[2]] = "";
                    return promiseWith({ out: "Log cleared.\n" });
                }
                if (args[1] === "backup")
                    return promiseWith({
                        run: (res, rej, stream) => {
                            const folder = args[2] || "/etc";
                            mockRunning.push({ name: "backup-manual.tar.gz", folder, trigger: "manual" });
                            const lines = ["Backing up " + folder,
                                "  Archive: /var/backups/cockpit-backup/backup-…-20260807-091500.tar.gz",
                                "  Size: 700M", "Removing backups older than retention…", "Done."];
                            let i = 0;
                            const t = setInterval(() => {
                                if (i < lines.length) stream(lines[i++] + "\n");
                                else {
                                    clearInterval(t);
                                    const idx = mockRunning.findIndex(r => r.folder === folder && r.trigger === "manual");
                                    if (idx !== -1) mockRunning.splice(idx, 1);
                                    res();
                                }
                            }, 350);
                        }
                    });
                if (args[1] === "apply-schedule")
                    return promiseWith({ out: "Schedule applied.\n" });
                if (args[1] === "test-s3")
                    return promiseWith({
                        run: (res) => setTimeout(() =>
                            res("S3 connection OK: bucket 'my-backups' is reachable\n"), 700)
                    });
                if (args[1] === "estimate")
                    return promiseWith({
                        run: (res, rej, stream) => {
                            setTimeout(() => res(JSON.stringify({ bytes: 731906048, files: 3421 })), 800);
                        }
                    });
                if (args[1] === "restore")
                    return promiseWith({
                        run: (res, rej, stream) => {
                            // Simulate: download from S3 (2 steps) then extract (2 steps)
                            const emit = o => stream("@@P@@ " + JSON.stringify(o) + "\n");
                            stream("Downloading from S3: " + args[2] + " …\n");
                            let dl = 0;
                            const t1 = setInterval(() => {
                                dl += 34;
                                if (dl >= 100) {
                                    clearInterval(t1);
                                    stream("Restoring " + args[2] + " to / …\n");
                                    let ex = 0;
                                    const t2 = setInterval(() => {
                                        ex += 30;
                                        if (ex >= 100) {
                                            clearInterval(t2);
                                            emit({ phase: "done", member: 1, members: 1, pct: 100, eta: 0 });
                                            stream("Restore completed.\n");
                                            res();
                                            return;
                                        }
                                        emit({ phase: "extract", member: 1, members: 1, pct: Math.min(99, ex), eta: Math.round((100 - ex) / 30 * 0.8) });
                                    }, 700);
                                    return;
                                }
                                emit({ phase: "download", member: 1, members: 1, pct: Math.min(99, dl), eta: Math.round((100 - dl) / 34 * 0.7) });
                            }, 700);
                        }
                    });
                return promiseWith({ out: "" });
            }
        };
    })();
    console.info("cockpit.js not found: preview mode with sample data");
}

/* ---------- Constants / state ---------- */

const HELPER = "/usr/local/libexec/cockpit-backup/cockpit-backup.sh";
const CONFIG_PATH = "/etc/cockpit-backup/config.json";
const OTHER = "__other__";

const DEFAULT_CONFIG = {
    destination: "/var/backups/cockpit-backup",
    retention_days: 30,
    backups: []
};
const DEFAULT_TIME = "02:00";

function entryTimesList(b) {
    const ts = (b.times && b.times.length) ? b.times : [b.time || config.time || DEFAULT_TIME];
    return ts.slice().sort();
}
function entryTime(b) { return entryTimesList(b)[0]; }

/* Retention tiers: canonical order is finest unit first, larger keep first
 * within the same unit — mirrors the backend's norm_policy() */
const TIER_UNIT_ORDER = { hour: 0, day: 1, week: 2, month: 3, year: 4 };
const TIER_PLURAL = { hour: "hours", day: "days", week: "weeks", month: "months", year: "years" };
const TIER_ABBR = { hour: "h", day: "d", week: "w", month: "m", year: "y" };
const TIER_DEFAULT_SPAN = { hour: 24, day: 7, week: 4, month: 12, year: 3 };
const MAX_TIERS = 8;

function sortTiers(tiers) {
    return tiers.slice().sort((a, b) =>
        (TIER_UNIT_ORDER[a.per] - TIER_UNIT_ORDER[b.per]) || (b.keep - a.keep));
}

/* Either policy shape → canonical [{keep, per, span}, …]; malformed tiers dropped */
function tiersFromPolicy(pol) {
    const tiers = [];
    const push = (keep, per, span) => {
        keep = parseInt(keep, 10);
        span = parseInt(span, 10);
        if (keep >= 1 && span >= 1)
            tiers.push({ keep, per, span });
    };
    if (Array.isArray(pol)) {
        pol.forEach(t => {
            if (t && TIER_UNIT_ORDER[t.per] !== undefined)
                push(t.keep, t.per, t.span);
        });
    } else if (pol && typeof pol === "object") {
        [["daily", "day", "days"], ["weekly", "week", "weeks"],
         ["monthly", "month", "months"], ["yearly", "year", "years"]].forEach(([k, per, spanKey]) => {
            if (pol[k]) push(pol[k].keep, per, pol[k][spanKey]);
        });
    }
    return sortTiers(tiers);
}

/* Human summary of an entry's retention: flat days or tiered policy */
function retentionLabel(b) {
    const pol = b.retention;
    if (pol && typeof pol === "object") {
        const parts = tiersFromPolicy(pol).map(t =>
            t.keep + "/" + t.per + " for " + t.span + TIER_ABBR[t.per]);
        return "tiered: " + parts.join(", ");
    }
    return "keeps " + (b.retention_days || config.retention_days) + " days";
}

let config = { ...DEFAULT_CONFIG };
let archives = [];
let disk = null;           // destination filesystem usage (from `list`)
let running = [];          // backups currently in progress (from `list`)
let runningPrev = new Map(); // folder -> trigger, for start/finish notifications
let archivesLoaded = false;
let backupConsoleFolder = null; // which folder the "Backup now" output belongs to

let editingIndex = -1;      // config being edited in the modal (-1 = new)
let deletingIndex = -1;     // config being removed
let restoreArchive = null;  // archive shown in the restore modal
let deleteArchiveName = null;

const $ = id => document.getElementById(id);

const configFile = cockpit.file(CONFIG_PATH, { superuser: "try", syntax: JSON });

/* ---------- Toasts ---------- */

function toast(message, type = "info") {
    const el = document.createElement("div");
    el.className = "toast" + (type === "success" ? " toast-success" : type === "danger" ? " toast-danger" : "");
    el.textContent = message;
    $("toasts").appendChild(el);
    setTimeout(() => {
        el.classList.add("hide");
        setTimeout(() => el.remove(), 300);
    }, 4200);
}

function errText(err) {
    return (err && (err.message || err.problem)) || String(err);
}

/* ---------- Icons ---------- */

const ICONS = {
    edit: '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M11.013 1.427a1.75 1.75 0 0 1 2.474 0l1.086 1.086a1.75 1.75 0 0 1 0 2.474l-8.61 8.61c-.21.21-.47.364-.756.445l-3.251.93a.75.75 0 0 1-.927-.928l.929-3.25c.081-.286.235-.547.445-.758l8.61-8.609Zm1.414 1.06a.25.25 0 0 0-.354 0L10.811 3.75l1.439 1.44 1.263-1.263a.25.25 0 0 0 0-.354l-1.086-1.086ZM11.189 6.25 9.75 4.81l-6.286 6.287a.25.25 0 0 0-.064.108l-.558 1.953 1.953-.558a.25.25 0 0 0 .108-.064l6.286-6.286Z"/></svg>',
    trash: '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M6.5 1.75V3h3V1.75a.25.25 0 0 0-.25-.25h-2.5a.25.25 0 0 0-.25.25ZM11 3V1.75A1.75 1.75 0 0 0 9.25 0h-2.5A1.75 1.75 0 0 0 5 1.75V3H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 14h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11Zm.14 1.5H4.86l.8 7.995c.013.127.12.255.249.255h5.285c.129 0 .236-.128.249-.255l.8-7.995Z"/></svg>',
    restore: '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 1a7 7 0 1 1-6.95 7.85.75.75 0 0 1 1.49-.19 5.5 5.5 0 1 0 1.37-4.37L5.53 5.9a.75.75 0 0 1-.53 1.28H1.75A.75.75 0 0 1 1 6.43V3.18a.75.75 0 0 1 1.28-.53l1.06 1.06A6.98 6.98 0 0 1 8 1Zm-.75 3.5a.75.75 0 0 1 1.5 0v3.19l2.03 2.03a.75.75 0 1 1-1.06 1.06L7.47 8.53a.75.75 0 0 1-.22-.53V4.5Z"/></svg>',
    download: '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 1a.75.75 0 0 1 .75.75v6.69l2.22-2.22a.75.75 0 1 1 1.06 1.06l-3.5 3.5a.75.75 0 0 1-1.06 0l-3.5-3.5a.75.75 0 1 1 1.06-1.06l2.22 2.22V1.75A.75.75 0 0 1 8 1ZM2.75 13a.75.75 0 0 0 0 1.5h10.5a.75.75 0 0 0 0-1.5H2.75Z"/></svg>',
    info: '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm9-3a1 1 0 1 1-2 0 1 1 0 0 1 2 0ZM6.75 7h1.5a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1 0-1.5h.5V8.5h-.5a.75.75 0 0 1 0-1.5Z"/></svg>'
};

function storageBadge(isRemote, tooltip) {
    const badge = document.createElement("span");
    badge.className = "storage-badge " + (isRemote ? "storage-s3" : "storage-local");
    badge.textContent = isRemote ? "S3" : "Local";
    badge.dataset.tooltip = tooltip;
    return badge;
}

/* Per-archive chip. Incremental chains: "Complete" (the full that opens the
 * chain) and "Delta" (its incremental members). Standard configs: "Standard". */
function levelBadge(item) {
    let text, cls, tip;
    if (item.level === 1) {
        text = "Delta"; cls = "level-delta";
        tip = "Delta: only the changes since the previous backup. Restore recombines the whole chain automatically.";
    } else if (item.level === 0) {
        text = "Baseline"; cls = "level-baseline";
        tip = "Baseline: the full backup that opens an incremental chain; its Delta backups build on it.";
    } else {
        text = "Full"; cls = "level-full";
        tip = "Full backup: a complete, self-contained archive (not part of an incremental chain).";
    }
    const badge = document.createElement("span");
    badge.className = "level-badge " + cls;
    badge.textContent = text;
    badge.dataset.tooltip = tip;
    return badge;
}

function iconButton(icon, tooltip, onClick, variant) {
    const btn = document.createElement("button");
    btn.className = "btn btn-icon" + (variant ? " btn-icon-" + variant : "");
    btn.dataset.tooltip = tooltip;
    btn.setAttribute("aria-label", tooltip);
    btn.innerHTML = ICONS[icon];
    btn.addEventListener("click", ev => {
        ev.stopPropagation();
        onClick(ev);
    });
    return btn;
}

/* ---------- UI helpers ---------- */

function setLoading(btn, loading) {
    btn.disabled = loading;
    btn.classList.toggle("loading", loading);
}

function openModal(id) { $(id).hidden = false; }
function closeModal(id) { $(id).hidden = true; }

function formatSize(bytes) {
    if (bytes < 1024) return bytes + " B";
    const units = ["KB", "MB", "GB", "TB"];
    let v = bytes, u = -1;
    do { v /= 1024; u++; } while (v >= 1024 && u < units.length - 1);
    return v.toFixed(1) + " " + units[u];
}

function formatAge(mtime) {
    const s = Math.max(0, Math.floor(Date.now() / 1000) - mtime);
    if (s < 3600) return Math.max(1, Math.floor(s / 60)) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    const d = Math.floor(s / 86400);
    return d === 1 ? "yesterday" : d + " days ago";
}

/* ---------- Routing ---------- */

function currentRoute() {
    const h = location.hash;
    if (h.startsWith("#/b/")) return decodeURIComponent(h.slice(4));
    if (h === "#/other") return OTHER;
    return null; // list view
}

function goTo(folder) {
    if (folder === null) location.hash = "#/";
    else if (folder === OTHER) location.hash = "#/other";
    else location.hash = "#/b/" + encodeURIComponent(folder);
}

function render() {
    const route = currentRoute();
    const isList = route === null;
    $("view-list").hidden = !isList;
    $("view-detail").hidden = isList;
    if (isList) renderListView();
    else renderDetailView(route);
}

/* ---------- Data loading ---------- */

function loadConfig() {
    return configFile.read()
        .then(content => {
            const c = content || {};
            config = { ...DEFAULT_CONFIG, ...c };
            // Migrate legacy schema: folders: [...] → backups: [{folder, retention_days}]
            if (!c.backups && Array.isArray(c.folders)) {
                config.backups = c.folders.map(f => ({
                    folder: f,
                    retention_days: c.retention_days || DEFAULT_CONFIG.retention_days
                }));
            }
            if (!Array.isArray(config.backups)) config.backups = [];
        })
        .catch(() => { config = { ...DEFAULT_CONFIG }; });
}

function displayName(folder) {
    const entry = config.backups.find(b => b.folder === folder);
    return (entry && entry.title) || folder;
}

/* Toast when an automatic backup starts or finishes (manual ones already
 * give feedback through their own button/console). For S3 backups the finish
 * message reflects the real outcome: uploaded, or kept locally on failure. */
function notifyRunningTransitions() {
    const current = new Map(running.map(r => [r.folder, { trigger: r.trigger || "manual", remote: !!r.remote }]));
    current.forEach((info, folder) => {
        if (!runningPrev.has(folder) && info.trigger !== "manual")
            toast("Automatic backup in progress: " + displayName(folder) +
                (info.remote ? " (uploading to S3)" : ""), "info");
    });
    runningPrev.forEach((info, folder) => {
        if (current.has(folder) || info.trigger === "manual")
            return;
        if (info.remote) {
            // The freshly refreshed archive list tells us how it ended
            const newest = archives
                .filter(a => a.folder === folder)
                .sort((a, b) => b.mtime - a.mtime)[0];
            if (newest && newest.remote)
                toast("Backup uploaded to S3: " + displayName(folder), "success");
            else
                toast("S3 upload failed: backup kept locally — " + displayName(folder), "danger");
        } else {
            toast("Backup finished: " + displayName(folder), "success");
        }
    });
    runningPrev = current;
}

function refreshArchives() {
    return cockpit.spawn([HELPER, "list"], { superuser: "try", err: "message" })
        .then(out => {
            let data;
            try { data = JSON.parse(out); } catch (e) { data = []; }
            if (Array.isArray(data)) {          // older backend: plain archive list
                archives = data;
                running = [];
                disk = null;
            } else {
                archives = data.archives || [];
                running = data.running || [];
                disk = data.disk || null;
            }
            archivesLoaded = true;
            notifyRunningTransitions();
        })
        .catch(err => {
            archives = [];
            running = [];
            archivesLoaded = true;
            toast("Failed to load archives: " + errText(err), "danger");
        });
}

function isRunning(folder) {
    return running.some(r => r.folder === folder);
}

function formatDuration(s) {
    s = Math.max(0, Math.round(s));
    if (s < 60) return s + "s";
    const m = Math.floor(s / 60), ss = s % 60;
    if (m < 60) return m + "m " + (ss ? ss + "s" : "");
    const h = Math.floor(m / 60);
    return h + "h " + (m % 60) + "m";
}

/* Human text for a running backup: "<Phase> (N of M) · 62% · ETA 40s".
 * When there's no percentage yet (scan without a baseline, or an indeterminate
 * archive), it falls back to the phase + detail. */
function progressText(r) {
    const labels = { scan: "Scanning", archive: "Backing up", upload: "Uploading to S3" };
    let s = labels[r.phase] || "Working";
    if (r.steps > 1) s += " (" + (r.step || 1) + " of " + r.steps + ")";
    if (typeof r.pct === "number") {
        s += " · " + r.pct + "%";
        if (typeof r.eta === "number") s += " · ETA " + formatDuration(r.eta);
    } else if (r.detail) {
        s += " · " + r.detail;
    } else {
        s += "…";
    }
    return s;
}

/* Full-width progress strip shown under a running config row */
function progressRow(r) {
    const li = document.createElement("li");
    li.className = "config-progress";
    const spin = document.createElement("span");
    spin.className = "row-spinner";
    const text = document.createElement("span");
    text.className = "progress-text";
    text.textContent = progressText(r);
    li.appendChild(spin);
    li.appendChild(text);
    return li;
}

function archivesFor(folder) {
    if (folder === OTHER) {
        const configured = new Set(config.backups.map(b => b.folder));
        return archives.filter(a => !a.folder || !configured.has(a.folder));
    }
    return archives.filter(a => a.folder === folder);
}

/* ---------- List view ---------- */

let destDirty = false;

function renderListView() {
    const destInput = $("destination");
    if (!destDirty && document.activeElement !== destInput)   // don't clobber edits
        destInput.value = config.destination;
    renderS3();
    checkTimerEngine();

    $("config-loading").hidden = true;

    const list = $("config-list");
    list.innerHTML = "";

    const countBadge = $("config-count");
    countBadge.hidden = config.backups.length === 0;
    countBadge.textContent = config.backups.length;

    // Overall space used by archives, split by storage (local disk vs S3)
    const localArchives = archives.filter(a => !a.remote);
    const s3Archives = archives.filter(a => a.remote);
    const grandTotal = localArchives.reduce((s, a) => s + a.size, 0);
    const s3Total = s3Archives.reduce((s, a) => s + a.size, 0);
    const totalParts = [];
    if (localArchives.length > 0) totalParts.push(formatSize(grandTotal) + " local");
    if (s3Archives.length > 0) totalParts.push(formatSize(s3Total) + " on S3");
    $("config-total").textContent = totalParts.join(" · ");

    // Free space on the destination disk, red when below 10 GB
    const diskEl = $("disk-free");
    if (disk && typeof disk.free === "number") {
        const low = disk.free < 10 * 1024 * 1024 * 1024;
        diskEl.textContent = "· " + formatSize(disk.free) + " free on disk";
        diskEl.classList.toggle("disk-low", low);
        diskEl.hidden = false;
    } else {
        diskEl.hidden = true;
    }

    const orphans = archivesLoaded ? archivesFor(OTHER) : [];
    const empty = config.backups.length === 0 && orphans.length === 0;
    $("config-empty").hidden = !empty;
    list.hidden = empty;
    if (empty) return;

    // Sorted by daily time (then by name); indexes stay bound to the config array
    config.backups
        .map((b, idx) => ({ b, idx }))
        .sort((x, y) =>
            entryTime(x.b).localeCompare(entryTime(y.b)) ||
            (x.b.title || x.b.folder).localeCompare(y.b.title || y.b.folder))
        .forEach(({ b, idx }) => {
            list.appendChild(configRow(b, idx));
            const r = running.find(x => x.folder === b.folder);
            if (r) list.appendChild(progressRow(r));
        });

    if (orphans.length > 0)
        list.appendChild(otherRow(orphans));
}

function configRow(b, idx) {
    const items = archivesFor(b.folder);
    const total = items.reduce((s, a) => s + a.size, 0);
    const last = items.length ? items[0].mtime : null;

    const li = document.createElement("li");
    li.className = "config-row";
    li.tabIndex = 0;
    li.setAttribute("role", "link");

    const main = document.createElement("div");
    main.className = "config-main";

    const path = document.createElement("span");
    path.className = b.title ? "config-title" : "config-path";
    path.textContent = b.title || b.folder;
    path.appendChild(storageBadge(!!b.s3, b.s3
        ? "Backups are uploaded to the S3 bucket"
        : "Backups are stored on the local disk"));
    const mb = document.createElement("span");
    if (b.mode === "incremental") {
        mb.className = "mode-badge mode-incremental";
        mb.textContent = "Incremental";
        mb.dataset.tooltip = "Incremental backups: a Baseline archive every " +
            (b.full_every || 7) + " days, only the Delta changes in between";
    } else {
        mb.className = "mode-badge mode-standard";
        mb.textContent = "Standard";
        mb.dataset.tooltip = "Standard backups: a full, self-contained archive every time";
    }
    path.appendChild(mb);

    const meta = document.createElement("span");
    meta.className = "config-meta muted";
    const parts = [];
    parts.push(b.enabled === false
        ? "automatic backup off"
        : (b.every_hours
            ? "every " + b.every_hours + "h"
            : "daily at " + entryTimesList(b).join(" + ")));
    parts.push(retentionLabel(b));
    if (b.excludes && b.excludes.length)
        parts.push(b.excludes.length === 1 ? "1 exclusion" : b.excludes.length + " exclusions");
    meta.textContent = parts.join(" · ");

    main.appendChild(path);
    if (b.title) {
        const pathLine = document.createElement("span");
        pathLine.className = "config-pathline";
        pathLine.textContent = b.folder;
        main.appendChild(pathLine);
    }
    main.appendChild(meta);

    const stats = document.createElement("div");
    stats.className = "config-stats";
    stats.title = "Archives of this backup: total size, count and last run";
    const size = document.createElement("span");
    size.className = "config-size";
    size.textContent = items.length ? formatSize(total) : "—";
    const statsSub = document.createElement("span");
    statsSub.className = "config-stats-sub";
    statsSub.textContent = items.length
        ? (items.length === 1 ? "1 archive" : items.length + " archives") + " · last " + formatAge(last)
        : "no backups yet";
    stats.appendChild(size);
    stats.appendChild(statsSub);

    const actions = document.createElement("div");
    actions.className = "config-actions";
    actions.appendChild(stats);

    const toggleWrap = document.createElement("label");
    toggleWrap.className = "switch switch-sm";
    toggleWrap.dataset.tooltip = b.enabled !== false ? "Daily backup enabled" : "Daily backup disabled";
    const toggleInput = document.createElement("input");
    toggleInput.type = "checkbox";
    toggleInput.checked = b.enabled !== false;
    const slider = document.createElement("span");
    slider.className = "slider";
    toggleWrap.appendChild(toggleInput);
    toggleWrap.appendChild(slider);
    toggleWrap.addEventListener("click", ev => ev.stopPropagation());
    toggleInput.addEventListener("change", () => {
        toggleWrap.dataset.tooltip = toggleInput.checked ? "Daily backup enabled" : "Daily backup disabled";
        toggleEntry(idx, toggleInput.checked);
    });

    const editBtn = iconButton("edit", "Edit", () => openConfigDialog(idx), "warning");
    const removeBtn = iconButton("trash", "Remove", () => openConfigDeleteDialog(idx), "danger");

    const chevron = document.createElement("span");
    chevron.className = "chevron";
    chevron.textContent = "›";

    actions.appendChild(toggleWrap);
    actions.appendChild(editBtn);
    actions.appendChild(removeBtn);
    actions.appendChild(chevron);

    li.appendChild(main);
    li.appendChild(actions);

    li.addEventListener("click", () => goTo(b.folder));
    li.addEventListener("keydown", ev => { if (ev.key === "Enter") goTo(b.folder); });
    return li;
}

function otherRow(orphans) {
    const total = orphans.reduce((s, a) => s + a.size, 0);

    const li = document.createElement("li");
    li.className = "config-row config-row-other";
    li.tabIndex = 0;

    const main = document.createElement("div");
    main.className = "config-main";

    const path = document.createElement("span");
    path.className = "config-path muted";
    path.textContent = "Other archives";

    const meta = document.createElement("span");
    meta.className = "config-meta muted";
    meta.textContent = "from folders no longer configured";

    main.appendChild(path);
    main.appendChild(meta);

    const stats = document.createElement("div");
    stats.className = "config-stats";
    const size = document.createElement("span");
    size.className = "config-size";
    size.textContent = formatSize(total);
    const statsSub = document.createElement("span");
    statsSub.className = "config-stats-sub";
    statsSub.textContent = orphans.length === 1 ? "1 archive" : orphans.length + " archives";
    stats.appendChild(size);
    stats.appendChild(statsSub);

    const actions = document.createElement("div");
    actions.className = "config-actions";
    actions.appendChild(stats);
    const chevron = document.createElement("span");
    chevron.className = "chevron";
    chevron.textContent = "›";
    actions.appendChild(chevron);

    li.appendChild(main);
    li.appendChild(actions);

    li.addEventListener("click", () => goTo(OTHER));
    li.addEventListener("keydown", ev => { if (ev.key === "Enter") goTo(OTHER); });
    return li;
}

/* ---------- Detail view ---------- */

function renderDetailView(folder) {
    const isOther = folder === OTHER;
    const entry = config.backups.find(b => b.folder === folder);

    // Unknown folder (e.g. stale link after removal) → back to list
    if (!isOther && !entry && archivesFor(folder).length === 0) {
        goTo(null);
        return;
    }

    const heading = isOther ? "Other archives" : ((entry && entry.title) || folder);
    $("detail-title").textContent = heading;
    $("detail-title").classList.toggle("mono-title", !isOther && !(entry && entry.title));
    $("detail-backup-card").hidden = isOther || !entry;

    // The manual-backup output belongs to the folder it was launched on: show it
    // only in that folder's detail view, never leaking into another config's.
    $("backup-console").hidden = isOther || !entry || backupConsoleFolder !== folder;

    // Live progress strip (phase · step · % · ETA) above the output, mirroring
    // the one on the list, while a backup of this folder is running.
    const detailProgress = $("detail-progress");
    detailProgress.innerHTML = "";
    const runInfo = isOther ? null : running.find(x => x.folder === folder);
    if (runInfo) detailProgress.appendChild(progressRow(runInfo));

    // Always show the backed-up path prominently, even when a title is set
    const pathEl = $("detail-path");
    pathEl.hidden = isOther || !(entry && entry.title);
    pathEl.textContent = pathEl.hidden ? "" : folder;

    // While a backup of this folder is in progress, block a second manual run
    $("detail-backup-now").disabled = !isOther && isRunning(folder);

    // Backup log (per configured folder only)
    $("detail-log-card").hidden = isOther || !entry;
    if (!isOther && entry)
        loadLog(folder);

    const items = archivesFor(folder);
    const total = items.reduce((s, a) => s + a.size, 0);
    const s3Items = items.filter(a => a.remote);
    const localItems = items.filter(a => !a.remote);
    const s3Total = s3Items.reduce((s, a) => s + a.size, 0);
    const localTotal = localItems.reduce((s, a) => s + a.size, 0);

    const countBadge = $("archive-count");
    countBadge.hidden = items.length === 0;
    countBadge.textContent = items.length;

    $("list-empty").hidden = items.length > 0;
    $("list-table-wrap").hidden = items.length === 0;
    $("detail-total").textContent = formatSize(total);
    let totalLabel = "Total · " + (items.length === 1 ? "1 archive" : items.length + " archives");
    if (s3Items.length > 0 && localItems.length > 0)
        totalLabel += " · " + formatSize(localTotal) + " local · " + formatSize(s3Total) + " on S3";
    else if (s3Items.length > 0)
        totalLabel += " · " + formatSize(s3Total) + " on S3";
    $("detail-total-label").textContent = totalLabel;

    const tbody = $("backup-rows");
    tbody.innerHTML = "";
    items.forEach(item => tbody.appendChild(archiveRow(item)));
}

function archiveRow(item) {
    const tr = document.createElement("tr");

    const tdName = document.createElement("td");
    tdName.className = "archive-name";

    const nameText = document.createElement("div");
    nameText.className = "archive-name-text";
    nameText.textContent = item.name;
    tdName.appendChild(nameText);

    // Badges live on their own line below the name
    const badges = document.createElement("div");
    badges.className = "archive-badges";
    badges.appendChild(storageBadge(!!item.remote, item.remote
        ? "Stored on the S3 bucket (restore downloads it automatically)"
        : "Stored on the local destination disk"));
    const lvl = levelBadge(item);
    if (lvl) badges.appendChild(lvl);
    if (item.trigger === "catchup") {
        const info = document.createElement("span");
        info.className = "catchup-info";
        info.dataset.tooltip = "Catch-up backup: the scheduled time was missed, so it ran later";
        info.innerHTML = ICONS.info;
        badges.appendChild(info);
    }
    tdName.appendChild(badges);

    const tdDate = document.createElement("td");
    tdDate.textContent = new Date(item.mtime * 1000).toLocaleString("en-US",
        { dateStyle: "medium", timeStyle: "short" });

    const tdAge = document.createElement("td");
    tdAge.className = "muted";
    tdAge.textContent = formatAge(item.mtime);

    const tdSize = document.createElement("td");
    tdSize.className = "col-right";
    tdSize.textContent = formatSize(item.size);

    const tdActions = document.createElement("td");
    tdActions.className = "cell-actions";
    tdActions.appendChild(iconButton("restore", "Restore", () => openRestoreDialog(item), "primary"));
    if (!item.remote)   // download streams the local file; remote ones live on S3
        tdActions.appendChild(iconButton("download", "Download", () => downloadArchive(item), "success"));
    const delBtn = iconButton("trash", "Delete", () => openDeleteDialog(item.name), "danger");
    if (item.remote && !s3Ready()) {
        // Deleting now would orphan the object on the bucket
        delBtn.disabled = true;
        delBtn.dataset.tooltip = "Enable S3 to delete this remote archive";
    }
    tdActions.appendChild(delBtn);

    tr.appendChild(tdName);
    tr.appendChild(tdDate);
    tr.appendChild(tdAge);
    tr.appendChild(tdSize);
    tr.appendChild(tdActions);
    return tr;
}

/* ---------- Configuration add / edit / remove ---------- */

function saveConfigFile() {
    return configFile.replace(config);
}

/* Regenerates the systemd timer's OnCalendar entries after any change
 * that can affect the schedule (time, enabled flag, add/remove). */
function applySchedule() {
    return cockpit.spawn([HELPER, "apply-schedule"], { superuser: "require", err: "message" })
        .catch(err => toast("Failed to update the schedule: " + errText(err), "danger"));
}

/* Schedule editor state: the times of the entry being edited */
let modalTimes = [];

function renderTimesList() {
    const list = $("times-list");
    list.innerHTML = "";
    modalTimes.slice().sort().forEach(t => {
        const chip = document.createElement("span");
        chip.className = "time-chip";
        const label = document.createElement("span");
        label.textContent = t;
        const rm = document.createElement("button");
        rm.className = "time-chip-remove";
        rm.textContent = "✕";
        rm.setAttribute("aria-label", "Remove " + t);
        rm.addEventListener("click", () => {
            modalTimes = modalTimes.filter(x => x !== t);
            renderTimesList();
        });
        chip.appendChild(label);
        chip.appendChild(rm);
        list.appendChild(chip);
    });
    if (!modalTimes.length) {
        const empty = document.createElement("span");
        empty.className = "muted small";
        empty.textContent = "No times yet — add at least one.";
        list.appendChild(empty);
    }
    updateTierHint();
}

function addModalTime() {
    const t = $("config-new-time").value;
    if (!t) return;
    if (!modalTimes.includes(t))
        modalTimes.push(t);
    renderTimesList();
}

let modalTiers = [];

function updateSchedulePanels() {
    const every = $("sched-every").checked;
    $("schedule-times").hidden = every;
    $("schedule-every").hidden = !every;
    updateTierHint();
}

function updateRetentionPanels() {
    const tiered = $("ret-tiered").checked;
    $("retention-simple").hidden = tiered;
    $("retention-tiered").hidden = !tiered;
    updateTierHint();
}

/* Rows are kept in canonical order (finest unit first, larger keep first);
 * a unit or keep change re-sorts, so no manual reordering is ever needed. */
function renderTierList() {
    modalTiers = sortTiers(modalTiers);
    const list = $("tier-list");
    list.innerHTML = "";
    const cell = (tag, cls, text) => {
        const el = document.createElement(tag);
        if (cls) el.className = cls;
        if (text !== undefined) el.textContent = text;
        list.appendChild(el);
        return el;
    };
    modalTiers.forEach((t, i) => {
        cell("span", "tier-word", i === 0 ? "keep" : "then");
        const keep = cell("input");
        keep.type = "number";
        keep.min = 1; keep.max = 100;
        keep.value = t.keep;
        keep.addEventListener("input", () => {
            t.keep = Math.min(100, Math.max(1, parseInt(keep.value, 10) || 1));
        });
        keep.addEventListener("change", renderTierList);
        cell("span", "tier-for", "per");
        const per = cell("select");
        Object.keys(TIER_UNIT_ORDER).forEach(u => {
            const o = document.createElement("option");
            o.value = u;
            o.textContent = u;
            per.appendChild(o);
        });
        per.value = t.per;
        per.addEventListener("change", () => {
            t.per = per.value;
            t.span = TIER_DEFAULT_SPAN[t.per];
            renderTierList();
        });
        cell("span", "tier-for", "for");
        const span = cell("input");
        span.type = "number";
        span.min = 1; span.max = 3650;
        span.value = t.span;
        span.addEventListener("input", () => {
            t.span = Math.min(3650, Math.max(1, parseInt(span.value, 10) || 1));
        });
        span.addEventListener("change", renderTierList);
        cell("span", "tier-word", t.span === 1 ? t.per : TIER_PLURAL[t.per]);
        const rm = cell("button", "tier-remove", "✕");
        rm.setAttribute("aria-label", "Remove tier");
        rm.addEventListener("click", () => {
            modalTiers.splice(i, 1);
            renderTierList();
        });
    });
    if (!modalTiers.length) {
        const empty = document.createElement("span");
        empty.className = "muted small";
        empty.style.gridColumn = "1 / -1";
        empty.textContent = "No tiers yet — add at least one.";
        list.appendChild(empty);
    }
    $("tier-add").disabled = modalTiers.length >= MAX_TIERS;
    updateTierHint();
}

function addModalTier() {
    if (modalTiers.length >= MAX_TIERS)
        return;
    // Default to one unit coarser than the coarsest tier already present
    const units = Object.keys(TIER_UNIT_ORDER);
    let unit = "day";
    if (modalTiers.length) {
        const coarsest = Math.max(...modalTiers.map(t => TIER_UNIT_ORDER[t.per]));
        unit = units[Math.min(coarsest + 1, units.length - 1)];
    }
    modalTiers.push({ keep: 1, per: unit, span: TIER_DEFAULT_SPAN[unit] });
    renderTierList();
}

/* Informational only: the schedule caps how many backups per day can exist —
 * a more generous "keep" is harmless, its buckets simply never fill. */
function updateTierHint() {
    const hint = $("tier-d-hint");
    const every = $("sched-every").checked;
    const n = parseInt($("config-every-hours").value, 10) || 6;
    const runs = every ? Math.max(1, Math.round(24 / n)) : Math.max(1, modalTimes.length);
    hint.textContent = "The schedule produces up to " + runs + " backup" +
        (runs === 1 ? "" : "s") + " per day.";
    hint.hidden = !$("ret-tiered").checked;
}

function openConfigDialog(idx) {
    editingIndex = idx;
    $("config-title").textContent = idx === -1 ? "Add backup" : "Edit backup";
    $("config-name").value = idx === -1 ? "" : (config.backups[idx].title || "");
    $("config-folder").value = idx === -1 ? "" : config.backups[idx].folder;

    // Schedule: fixed daily times or an every-N-hours interval
    const everyH = idx !== -1 ? (parseInt(config.backups[idx].every_hours, 10) || 0) : 0;
    $("sched-every").checked = !!everyH;
    $("sched-times").checked = !everyH;
    const everySel = $("config-every-hours");
    if (everyH) {
        everySel.value = String(everyH);
        if (everySel.value !== String(everyH)) {
            // Preserve a hand-edited interval that isn't among the presets
            const o = document.createElement("option");
            o.value = String(everyH);
            o.textContent = everyH + " hours";
            everySel.appendChild(o);
            everySel.value = String(everyH);
        }
    }
    modalTimes = idx === -1 ? [DEFAULT_TIME] : entryTimesList(config.backups[idx]).slice();
    renderTimesList();
    $("config-new-time").value = DEFAULT_TIME;
    updateSchedulePanels();

    // Retention: simple day-count or tiered policy (list or legacy dict)
    const pol = idx !== -1 ? config.backups[idx].retention : null;
    modalTiers = tiersFromPolicy(pol);
    const hasPol = modalTiers.length > 0;
    if (!hasPol) {
        // Sensible default: keep as many per day as there are scheduled runs
        modalTiers = [
            { keep: Math.max(1, everyH ? Math.round(24 / everyH) : modalTimes.length), per: "day", span: 7 },
            { keep: 1, per: "week", span: 4 },
            { keep: 1, per: "month", span: 12 }
        ];
    }
    $("ret-tiered").checked = hasPol;
    $("ret-simple").checked = !hasPol;
    $("config-retention").value = idx === -1
        ? config.retention_days
        : (config.backups[idx].retention_days || config.retention_days);
    renderTierList();
    updateRetentionPanels();

    $("config-excludes").value = idx === -1
        ? ""
        : (config.backups[idx].excludes || []).join("\n");
    const storage = $("config-storage");
    const s3Option = storage.querySelector('option[value="s3"]');
    const entryUsesS3 = idx !== -1 && !!config.backups[idx].s3;
    s3Option.textContent = s3Ready() ? "Amazon S3 (remote)" : "Amazon S3 (currently disabled)";
    // An entry already on S3 keeps its choice even while S3 is globally off:
    // its backups fall back to local until S3 is re-enabled
    s3Option.disabled = !s3Ready() && !entryUsesS3;
    storage.value = entryUsesS3 ? "s3" : "local";
    $("config-storage-hint").hidden = s3Ready();
    const entryIncremental = idx !== -1 && config.backups[idx].mode === "incremental";
    $("config-mode").value = entryIncremental ? "incremental" : "full";
    $("config-full-every").value = idx === -1 ? 7 : (config.backups[idx].full_every || 7);
    updateModeField();
    $("estimate-result").textContent = "";
    showConfigError(null);
    openModal("config-dialog");
    $("config-folder").focus();
}

function updateModeField() {
    $("config-full-every-field").hidden = $("config-mode").value !== "incremental";
}

function showConfigError(msg) {
    const el = $("config-error");
    el.textContent = msg || "";
    el.hidden = !msg;
}

function saveConfigEntry() {
    const title = $("config-name").value.trim();
    const folder = $("config-folder").value.trim().replace(/\/+$/, "") || $("config-folder").value.trim();
    const retention = Math.max(1, parseInt($("config-retention").value, 10) || config.retention_days);
    const excludes = $("config-excludes").value
        .split("\n")
        .map(l => l.trim())
        .filter(l => l.length > 0);

    if (!folder || !folder.startsWith("/")) {
        showConfigError("Enter an absolute path, starting with /");
        return;
    }
    if (folder === "/") {
        showConfigError("The root filesystem cannot be backed up");
        return;
    }
    const clash = config.backups.findIndex(b => b.folder === folder);
    if (clash !== -1 && clash !== editingIndex) {
        showConfigError("This folder is already configured");
        return;
    }
    const schedEvery = $("sched-every").checked;
    const everyHours = Math.min(24, Math.max(1, parseInt($("config-every-hours").value, 10) || 6));
    if (!schedEvery && !modalTimes.length) {
        showConfigError("Add at least one backup time");
        return;
    }
    const times = modalTimes.slice().sort();

    const tiered = $("ret-tiered").checked;
    let policy = null;
    if (tiered) {
        policy = tiersFromPolicy(modalTiers).slice(0, MAX_TIERS);
        if (!policy.length) {
            showConfigError("Add at least one retention tier");
            return;
        }
    }

    const useS3 = $("config-storage").value === "s3";
    const incremental = $("config-mode").value === "incremental";
    const fullEvery = Math.max(1, parseInt($("config-full-every").value, 10) || 7);

    const entry = editingIndex === -1 ? { folder } : { ...config.backups[editingIndex], folder };
    if (schedEvery) {
        entry.every_hours = everyHours;
        delete entry.times;
    } else {
        entry.times = times;
        delete entry.every_hours;
    }
    delete entry.time;                 // superseded by times[] / every_hours
    if (tiered) {
        entry.retention = policy;
        delete entry.retention_days;
    } else {
        entry.retention_days = retention;
        delete entry.retention;
    }
    if (title) entry.title = title;
    else delete entry.title;
    if (excludes.length) entry.excludes = excludes;
    else delete entry.excludes;
    if (useS3) entry.s3 = true;
    else delete entry.s3;
    if (incremental) { entry.mode = "incremental"; entry.full_every = fullEvery; }
    else { delete entry.mode; delete entry.full_every; }

    if (editingIndex === -1)
        config.backups.push(entry);
    else
        config.backups[editingIndex] = entry;

    const btn = $("config-save");
    setLoading(btn, true);
    saveConfigFile()
        .then(applySchedule)
        .then(() => {
            closeModal("config-dialog");
            toast(editingIndex === -1 ? "Backup added" : "Backup updated", "success");
            if (incremental && fullEvery > retention)
                toast("Note: each full backup is kept beyond retention while its incrementals still need it", "info");
            renderListView();
        })
        .catch(err => toast("Failed to save: " + errText(err), "danger"))
        .finally(() => setLoading(btn, false));
}

function toggleEntry(idx, enabled) {
    const entry = config.backups[idx];
    entry.enabled = enabled;
    saveConfigFile()
        .then(applySchedule)
        .then(() => {
            toast(enabled
                ? "Automatic backup enabled for " + entry.folder
                : "Automatic backup disabled for " + entry.folder,
                enabled ? "success" : "info");
            renderListView();
        })
        .catch(err => {
            entry.enabled = !enabled;
            toast("Failed to save: " + errText(err), "danger");
            renderListView();
        });
}

function estimateSize() {
    const folder = $("config-folder").value.trim().replace(/\/+$/, "") || $("config-folder").value.trim();
    if (!folder || !folder.startsWith("/")) {
        showConfigError("Enter an absolute path first, then calculate the size");
        return;
    }
    showConfigError(null);
    const excludes = $("config-excludes").value
        .split("\n")
        .map(l => l.trim())
        .filter(l => l.length > 0);

    const btn = $("estimate-size");
    const result = $("estimate-result");
    setLoading(btn, true);
    result.textContent = "Calculating…";

    cockpit.spawn([HELPER, "estimate", folder].concat(excludes),
        { superuser: "try", err: "message" })
        .then(out => {
            const data = JSON.parse(out);
            result.textContent = "≈ " + formatSize(data.bytes) + " · " +
                data.files.toLocaleString("en-US") + " files" +
                (excludes.length ? " (exclusions applied)" : "");
        })
        .catch(err => {
            result.textContent = "";
            showConfigError("Could not calculate size: " + errText(err));
        })
        .finally(() => setLoading(btn, false));
}

function openConfigDeleteDialog(idx) {
    deletingIndex = idx;
    $("config-delete-name").textContent = config.backups[idx].folder;
    openModal("config-delete-dialog");
}

function confirmConfigDelete() {
    config.backups.splice(deletingIndex, 1);
    const btn = $("config-delete-confirm");
    setLoading(btn, true);
    saveConfigFile()
        .then(applySchedule)
        .then(() => {
            closeModal("config-delete-dialog");
            toast("Backup removed", "success");
            renderListView();
        })
        .catch(err => toast("Failed to save: " + errText(err), "danger"))
        .finally(() => setLoading(btn, false));
}

/* ---------- Global settings ---------- */

function saveSettings() {
    config.destination = $("destination").value.trim() || DEFAULT_CONFIG.destination;

    const btn = $("save-settings");
    setLoading(btn, true);
    saveConfigFile()
        .then(() => {
            destDirty = false;
            toast("Settings saved", "success");
        })
        .catch(err => toast("Failed to save: " + errText(err), "danger"))
        .finally(() => setLoading(btn, false));
}

/* ---------- S3 remote storage ---------- */

const S3_FIELD_IDS = ["s3-bucket", "s3-region", "s3-access-key", "s3-secret-key", "s3-prefix", "s3-endpoint"];

// True while the S3 form has unsaved edits: the periodic refresh must never
// overwrite what the user is typing (cleared on save)
let s3Dirty = false;
let s3Collapsed = true;   // the S3 card starts collapsed; the chevron toggles it

function s3Ready() {
    return !!(config.s3 && config.s3.enabled && config.s3.bucket);
}

function renderS3() {
    const s3 = config.s3 || {};
    const editing = S3_FIELD_IDS.some(id => document.activeElement === $(id));
    if (!s3Dirty && !editing) {
        $("s3-enabled").checked = !!s3.enabled;
        $("s3-bucket").value = s3.bucket || "";
        $("s3-region").value = s3.region || "";
        $("s3-access-key").value = s3.access_key || "";
        $("s3-secret-key").value = s3.secret_key || "";
        $("s3-prefix").value = s3.prefix || "";
        $("s3-endpoint").value = s3.endpoint || "";
    }
    const badge = $("s3-badge");
    badge.textContent = s3Ready() ? "Enabled" : "Disabled";
    badge.className = "badge " + (s3Ready() ? "badge-on" : "badge-off");

    // Expand/collapse the card body via the chevron (independent of enabled).
    $("s3-body").hidden = s3Collapsed;
    $("s3-toggle").classList.toggle("expanded", !s3Collapsed);
    // Drop the header's bottom margin when collapsed so the card padding stays
    // symmetric (otherwise there's extra space below the header)
    $("s3-body").previousElementSibling.classList.toggle("no-gap", s3Collapsed);
}

function gatherS3() {
    config.s3 = {
        enabled: $("s3-enabled").checked,
        bucket: $("s3-bucket").value.trim(),
        region: $("s3-region").value.trim(),
        access_key: $("s3-access-key").value.trim(),
        secret_key: $("s3-secret-key").value,
        prefix: $("s3-prefix").value.trim(),
        endpoint: $("s3-endpoint").value.trim()
    };
}

function saveS3(showToast) {
    gatherS3();
    if (config.s3.enabled && !config.s3.bucket) {
        toast("Enter the bucket name to enable S3", "danger");
        return Promise.reject(new Error("bucket missing"));
    }
    const btn = $("save-s3");
    setLoading(btn, true);
    return saveConfigFile()
        .then(() => {
            s3Dirty = false;
            if (showToast !== false) toast("S3 settings saved", "success");
            renderS3();
        })
        .catch(err => {
            toast("Failed to save: " + errText(err), "danger");
            throw err;
        })
        .finally(() => setLoading(btn, false));
}

function testS3() {
    const btn = $("test-s3");
    const result = $("s3-test-result");
    // Save first so the backend tests exactly what is on screen
    saveS3(false).then(() => {
        setLoading(btn, true);
        result.textContent = "Testing…";
        cockpit.spawn([HELPER, "test-s3"], { superuser: "require", err: "message" })
            .then(out => { result.textContent = out.trim(); })
            .catch(err => { result.textContent = "Failed: " + errText(err); })
            .finally(() => setLoading(btn, false));
    }).catch(() => { /* save error already shown */ });
}

/* ---------- Timer engine check ---------- */

/* The systemd timer is the engine behind per-folder schedules: it should always
 * be running (install.sh enables it). Only warn when it is missing or stopped. */
function checkTimerEngine() {
    cockpit.spawn(
        ["systemctl", "show", "cockpit-backup.timer",
         "--property=UnitFileState,ActiveState"],
        { superuser: "try", err: "message" })
        .then(out => {
            const props = {};
            out.trim().split("\n").forEach(line => {
                const i = line.indexOf("=");
                if (i > 0) props[line.slice(0, i)] = line.slice(i + 1);
            });
            const running = props.UnitFileState && props.ActiveState === "active";
            $("timer-warning").hidden = !!running;
        })
        .catch(() => { $("timer-warning").hidden = false; });
}

/* ---------- Backups (run) ---------- */

function runBackup(folder, btn, consoleWrap, consoleOut) {
    setLoading(btn, true);
    if (consoleWrap) {
        backupConsoleFolder = folder;                   // this output belongs to this folder
        consoleWrap.hidden = false;
        consoleOut.textContent = "";
        consoleOut.hidden = true;                       // output starts collapsed
        const tg = $("backup-console-toggle");
        if (tg) tg.classList.remove("expanded");
    }

    const args = folder ? [HELPER, "backup", folder] : [HELPER, "backup"];
    const proc = cockpit.spawn(args, { superuser: "require", err: "out" });
    if (consoleOut)
        proc.stream(data => {
            consoleOut.textContent += data;
            consoleOut.scrollTop = consoleOut.scrollHeight;
        });

    // Poll fast while this manual backup runs so the live progress strip shows
    // up immediately and stays smooth — even for quick backups the idle poll
    // would otherwise start-and-finish between.
    let polling = true;
    const pollNow = () => {
        if (!polling) return;
        refreshArchives().then(() => { render(); if (polling) setTimeout(pollNow, 1000); });
    };
    setTimeout(pollNow, 300);

    proc.then(() => {
        toast("Backup completed", "success");
    });
    proc.catch(err => {
        if (consoleOut) consoleOut.textContent += "\nError: " + errText(err) + "\n";
        toast("Backup failed", "danger");
    });
    proc.finally(() => {
        polling = false;
        setLoading(btn, false);
        refreshArchives().then(render);
    });
}

/* ---------- Backup log ---------- */

function loadLog(folder) {
    const body = $("log-body");
    cockpit.spawn([HELPER, "log", folder], { superuser: "try", err: "message" })
        .then(out => {
            const text = out.trim();
            body.classList.toggle("muted", !text);
            body.textContent = text || "No log entries yet.";
            body.scrollTop = body.scrollHeight;
        })
        .catch(err => {
            body.classList.add("muted");
            body.textContent = "Could not load the log: " + errText(err);
        });
}

function clearLog() {
    const folder = currentRoute();
    if (!folder || folder === OTHER) return;
    const btn = $("log-clear");
    setLoading(btn, true);
    cockpit.spawn([HELPER, "clear-log", folder], { superuser: "require", err: "message" })
        .then(() => {
            toast("Log cleared", "success");
            loadLog(folder);
        })
        .catch(err => toast("Failed to clear the log: " + errText(err), "danger"))
        .finally(() => setLoading(btn, false));
}

/* ---------- Archive download ---------- */

/* Streams the archive through a Cockpit fsread1 channel: the browser downloads
 * it directly, without buffering the whole file in memory. */
function downloadArchive(item) {
    if (!cockpit.transport || !cockpit.transport.csrf_token) {
        toast("Download is not available in preview mode", "info");
        return;
    }
    const path = config.destination.replace(/\/+$/, "") + "/" + item.name;
    const payload = {
        payload: "fsread1",
        binary: "raw",
        path,
        superuser: "try",
        max_read_size: 1099511627776,
        external: {
            "content-disposition": 'attachment; filename="' + item.name + '"',
            "content-type": "application/gzip"
        }
    };
    const url = "/cockpit/channel/" + cockpit.transport.csrf_token + "?" +
        window.btoa(JSON.stringify(payload));
    const a = document.createElement("a");
    a.href = url;
    a.download = item.name;
    document.body.appendChild(a);
    a.click();
    a.remove();
}

/* ---------- Archive delete ---------- */

function openDeleteDialog(name) {
    deleteArchiveName = name;
    $("delete-archive-name").textContent = name;
    // The backend refuses to delete an archive other backups build on; warn
    // upfront so the refusal doesn't come as a surprise
    const deps = archives.filter(a =>
        a.name !== name && (a.base === name || a.chain === name)).length;
    const warn = $("delete-chain-warning");
    if (deps > 0) {
        warn.textContent = deps + " Delta backup" + (deps === 1 ? "" : "s") +
            " of this chain depend" + (deps === 1 ? "s" : "") +
            " on this archive: delete those first (newest first).";
        warn.hidden = false;
    } else {
        warn.hidden = true;
    }
    openModal("delete-dialog");
}

function doDelete() {
    const btn = $("delete-confirm");
    setLoading(btn, true);
    cockpit.spawn([HELPER, "delete", deleteArchiveName], { superuser: "require", err: "message" })
        .then(() => {
            closeModal("delete-dialog");
            toast("Archive deleted", "success");
            return refreshArchives().then(render);
        })
        .catch(err => toast("Delete failed: " + errText(err), "danger"))
        .finally(() => setLoading(btn, false));
}

/* ---------- Restore ---------- */

function openRestoreDialog(item) {
    restoreArchive = item.name;
    $("restore-archive-name").textContent = item.name;

    const chainNote = $("restore-chain-note");
    if (item.level === 1) {
        chainNote.textContent = "Delta archive: the Baseline backup" +
            (item.chain ? " " + item.chain : "") +
            " and every Delta up to this point are restored in order, " +
            "including deletions made along the chain.";
        chainNote.hidden = false;
    } else {
        chainNote.hidden = true;
    }

    const pathsEl = $("restore-paths");
    pathsEl.innerHTML = "";
    if (item.folder) {
        const label = document.createElement("span");
        label.className = "restore-paths-label";
        label.textContent = "Restores to:";
        pathsEl.appendChild(label);
        const code = document.createElement("code");
        code.textContent = item.folder;
        pathsEl.appendChild(code);
        pathsEl.hidden = false;
    } else {
        pathsEl.hidden = true;
    }

    $("restore-console").hidden = true;
    $("restore-output").textContent = "";
    $("restore-output").hidden = true;                  // output starts collapsed
    $("restore-console-toggle").classList.remove("expanded");
    $("restore-progress").hidden = true;
    $("restore-progress").textContent = "";
    $("restore-target").value = "";
    $("restore-target").disabled = true;
    $("mode-original").checked = true;
    $("restore-warning").hidden = false;
    // Reset the footer: Restore + Cancel visible, OK hidden (a previous restore
    // may have left it showing OK)
    restoreProc = null;
    $("restore-confirm").hidden = false;
    $("restore-cancel").hidden = false;
    $("restore-ok").hidden = true;
    setLoading($("restore-confirm"), false);
    openModal("restore-dialog");
}

function updateRestoreMode() {
    const custom = $("mode-custom").checked;
    $("restore-target").disabled = !custom;
    $("restore-warning").hidden = custom;
    if (custom) $("restore-target").focus();
}

let restoreProc = null;   // the running restore process (for Cancel to abort)

function doRestore() {
    const custom = $("mode-custom").checked;
    const args = [HELPER, "restore", restoreArchive];
    if (custom) {
        const target = $("restore-target").value.trim();
        if (!target || !target.startsWith("/")) {
            toast("Enter an absolute path for the target folder", "danger");
            return;
        }
        args.push(target);
    }

    const out = $("restore-output");
    const btn = $("restore-confirm");
    $("restore-console").hidden = false;
    out.textContent = "";
    setLoading(btn, true);

    const prog = $("restore-progress");
    prog.hidden = true;
    prog.textContent = "";

    const proc = cockpit.spawn(args, { superuser: "require", err: "out" });
    restoreProc = proc;
    let buf = "";
    proc.stream(data => {
        buf += data;
        const lines = buf.split("\n");
        buf = lines.pop();   // keep the last, possibly-incomplete line
        lines.forEach(line => {
            if (line.startsWith("@@P@@ ")) {
                try { updateRestoreProgress(JSON.parse(line.slice(6))); } catch (e) { /* ignore */ }
            } else if (line.length) {
                out.textContent += line + "\n";
                out.scrollTop = out.scrollHeight;
            }
        });
    });
    proc.then(() => {
        toast("Restore completed", "success");
        restoreFinished();
    });
    proc.catch(err => {
        // A user-initiated abort rejects too — don't report it as a failure
        if (restoreProc === null) return;
        out.textContent += "\nError: " + errText(err) + "\n";
        toast("Restore failed", "danger");
        restoreFinished();
    });
    proc.finally(() => { setLoading(btn, false); restoreProc = null; });
}

/* Live restore progress line (parsed from @@P@@ stream lines). No spinner —
 * the Restore button already shows one. */
function updateRestoreProgress(p) {
    const el = $("restore-progress");
    if (p.phase === "done") { el.hidden = true; return; }
    const labels = { download: "Downloading from S3", extract: "Extracting" };
    let s = labels[p.phase] || "Working";
    if (p.members > 1) s += " (member " + p.member + " of " + p.members + ")";
    if (typeof p.pct === "number") {
        s += " · " + p.pct + "%";
        if (typeof p.eta === "number") s += " · ETA " + formatDuration(p.eta);
    } else if (p.detail) {
        s += " · " + p.detail;
    } else {
        s += "…";
    }
    el.textContent = s;
    el.hidden = false;
}

/* On completion swap Restore/Cancel for a single OK that closes the dialog */
function restoreFinished() {
    $("restore-confirm").hidden = true;
    $("restore-cancel").hidden = true;
    $("restore-ok").hidden = false;
}

/* Cancel: while a restore runs it aborts the process (with a warning, since a
 * half-finished restore may leave partially-written files); otherwise it just
 * closes the dialog. */
function restoreCancel() {
    if (restoreProc) {
        if (!confirm("Stop the restore now? Files already written are kept — the restore would be incomplete."))
            return;
        const p = restoreProc;
        restoreProc = null;      // mark as user-aborted before closing
        try { p.close("cancelled"); } catch (e) { /* already gone */ }
        $("restore-output").textContent += "\nRestore cancelled by user.\n";
        toast("Restore cancelled", "info");
        restoreFinished();
    } else {
        closeModal("restore-dialog");
    }
}

/* ---------- Init ---------- */

document.addEventListener("DOMContentLoaded", () => {
    // List view
    $("add-config").addEventListener("click", () => openConfigDialog(-1));
    $("config-save").addEventListener("click", saveConfigEntry);
    $("config-folder").addEventListener("keydown", ev => { if (ev.key === "Enter") saveConfigEntry(); });
    $("config-folder").addEventListener("input", () => showConfigError(null));
    $("config-delete-confirm").addEventListener("click", confirmConfigDelete);
    $("config-mode").addEventListener("change", updateModeField);
    $("config-add-time").addEventListener("click", addModalTime);
    $("config-new-time").addEventListener("keydown", ev => { if (ev.key === "Enter") addModalTime(); });
    $("sched-times").addEventListener("change", updateSchedulePanels);
    $("sched-every").addEventListener("change", updateSchedulePanels);
    $("config-every-hours").addEventListener("change", updateTierHint);
    $("ret-simple").addEventListener("change", updateRetentionPanels);
    $("ret-tiered").addEventListener("change", updateRetentionPanels);
    $("tier-add").addEventListener("click", addModalTier);
    $("estimate-size").addEventListener("click", estimateSize);
    $("save-settings").addEventListener("click", saveSettings);
    $("save-s3").addEventListener("click", () => saveS3());
    $("test-s3").addEventListener("click", testS3);
    $("s3-enabled").addEventListener("change", () => {
        if ($("s3-enabled").checked) s3Collapsed = false;   // auto-expand to configure
        saveS3();
    });
    $("s3-toggle").addEventListener("click", () => {
        s3Collapsed = !s3Collapsed;
        renderS3();
    });
    S3_FIELD_IDS.forEach(id =>
        $(id).addEventListener("input", () => { s3Dirty = true; }));
    $("destination").addEventListener("input", () => { destDirty = true; });

    // Detail view
    $("back-btn").addEventListener("click", () => goTo(null));
    $("detail-backup-now").addEventListener("click", () => {
        runBackup(currentRoute(), $("detail-backup-now"), $("backup-console"), $("backup-output"));
    });
    $("backup-console-close").addEventListener("click", () => {
        $("backup-console").hidden = true;
        backupConsoleFolder = null;
    });
    $("refresh-list").addEventListener("click", () => refreshArchives().then(render));

    // Output/log panels start collapsed; the chevron expands them on demand.
    const wireCollapse = (toggleId, bodyId) => {
        const t = $(toggleId), body = $(bodyId);
        if (!t || !body) return;
        t.addEventListener("click", () => {
            body.hidden = !body.hidden;
            t.classList.toggle("expanded", !body.hidden);
        });
    };
    wireCollapse("backup-console-toggle", "backup-output");
    wireCollapse("restore-console-toggle", "restore-output");
    wireCollapse("log-toggle", "log-body");

    // Modals
    $("restore-confirm").addEventListener("click", doRestore);
    $("restore-cancel").addEventListener("click", restoreCancel);
    $("delete-confirm").addEventListener("click", doDelete);
    $("mode-original").addEventListener("change", updateRestoreMode);
    $("mode-custom").addEventListener("change", updateRestoreMode);

    document.querySelectorAll("[data-close]").forEach(btn =>
        btn.addEventListener("click", () => closeModal(btn.dataset.close)));
    document.querySelectorAll(".modal-backdrop").forEach(backdrop =>
        backdrop.addEventListener("click", ev => { if (ev.target === backdrop) backdrop.hidden = true; }));
    document.addEventListener("keydown", ev => {
        if (ev.key === "Escape")
            document.querySelectorAll(".modal-backdrop").forEach(m => { m.hidden = true; });
    });

    // Log card
    $("log-refresh").addEventListener("click", () => {
        const folder = currentRoute();
        if (folder && folder !== OTHER) loadLog(folder);
    });
    $("log-clear").addEventListener("click", clearLog);

    window.addEventListener("hashchange", render);

    // Disk free space is rounded in the signature (100 MB steps): tiny
    // fluctuations must not trigger a full re-render every poll
    function listSig() {
        return JSON.stringify({
            a: archives, r: running,
            d: disk ? Math.round(disk.free / 1e8) : null
        });
    }
    let lastSig = "";
    function renderIfChanged() {
        if (listSig() !== lastSig) {
            lastSig = listSig();
            render();
        }
    }

    Promise.all([loadConfig(), refreshArchives()]).then(() => {
        lastSig = listSig();
        render();
    });

    // Keep the view in sync with backups started elsewhere (timer, other tabs):
    // the server-side markers survive page reloads. Poll fast while a backup is
    // running (so the phase/percentage strip updates smoothly), slow otherwise.
    function poll() {
        const delay = running.length ? 1500 : 5000;
        setTimeout(() => {
            refreshArchives().then(() => { renderIfChanged(); poll(); });
        }, delay);
    }
    poll();
});
