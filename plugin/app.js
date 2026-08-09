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
                { folder: "/home/roberto/documents", times: ["01:30", "13:30"], enabled: true,
                  retention: { daily: { keep: 2, days: 7 }, weekly: { keep: 1, weeks: 4 },
                               monthly: { keep: 1, months: 12 }, yearly: { keep: 1, years: 5 } } },
                { folder: "/var/www", time: "03:00", retention_days: 30, enabled: false, excludes: ["cache", "*.log"], title: "Web sites", mode: "incremental", full_every: 7 }
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
                            stream("Restoring " + args[2] + " …\n");
                            setTimeout(() => { stream("Restore completed.\n"); res(); }, 900);
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

/* Human summary of an entry's retention: flat days or tiered GFS policy */
function retentionLabel(b) {
    const pol = b.retention;
    if (pol && typeof pol === "object") {
        const parts = [];
        if (pol.daily) parts.push(pol.daily.keep + "/day for " + pol.daily.days + "d");
        if (pol.weekly) parts.push(pol.weekly.keep + "/week for " + pol.weekly.weeks + "w");
        if (pol.monthly) parts.push(pol.monthly.keep + "/month for " + pol.monthly.months + "m");
        if (pol.yearly) parts.push(pol.yearly.keep + "/year for " + pol.yearly.years + "y");
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

/* Full/Incr chip for archives of incremental-mode folders; classic archives
 * carry no level in their meta and get no chip. */
function levelBadge(item) {
    if (item.level !== 0 && item.level !== 1) return null;
    const badge = document.createElement("span");
    badge.className = "level-badge " + (item.level === 1 ? "level-incr" : "level-full");
    badge.textContent = item.level === 1 ? "Incremental" : "Full";
    badge.dataset.tooltip = item.level === 1
        ? "Only the changes since the previous backup. Restore combines the whole chain automatically."
        : "Full archive: starts a new incremental chain";
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

    // Overall disk usage of every LOCAL archive in the destination
    const localArchives = archives.filter(a => !a.remote);
    const grandTotal = localArchives.reduce((s, a) => s + a.size, 0);
    $("config-total").textContent = localArchives.length > 0 ? formatSize(grandTotal) + " local total" : "";

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
    if (b.mode === "incremental") {
        const mb = document.createElement("span");
        mb.className = "mode-badge";
        mb.textContent = "Incremental";
        mb.dataset.tooltip = "Incremental backups: a full archive every " +
            (b.full_every || 7) + " days, only the changes in between";
        path.appendChild(mb);
    }

    const meta = document.createElement("span");
    meta.className = "config-meta muted";
    const parts = [];
    parts.push(b.enabled === false
        ? "automatic backup off"
        : "daily at " + entryTimesList(b).join(" + "));
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

    const countBadge = $("archive-count");
    countBadge.hidden = items.length === 0;
    countBadge.textContent = items.length;

    $("list-empty").hidden = items.length > 0;
    $("list-table-wrap").hidden = items.length === 0;
    $("detail-total").textContent = formatSize(total);
    $("detail-total-label").textContent =
        "Total · " + (items.length === 1 ? "1 archive" : items.length + " archives");

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

function setTier(t, tier, defKeep, defSpan, spanKey) {
    $("tier-" + t + "-on").checked = !!tier;
    $("tier-" + t + "-keep").value = (tier && tier.keep) || defKeep;
    $("tier-" + t + "-span").value = (tier && tier[spanKey]) || defSpan;
}

function updateRetentionPanels() {
    const tiered = $("ret-tiered").checked;
    $("retention-simple").hidden = tiered;
    $("retention-tiered").hidden = !tiered;
    updateTierCascade();
}

/* Tiers form a chain: weekly needs daily, monthly needs weekly, yearly needs
 * monthly. Turning a tier off turns off and locks everything below it. */
function updateTierCascade() {
    const order = ["d", "w", "m", "y"];
    let parentOn = true;
    order.forEach(t => {
        const box = $("tier-" + t + "-on");
        if (!parentOn)
            box.checked = false;
        box.disabled = !parentOn;
        const on = box.checked;
        $("tier-" + t + "-keep").disabled = !on;
        $("tier-" + t + "-span").disabled = !on;
        // Dim the whole grid row (label + its 5 following cells) when disabled
        const label = box.closest(".tier-check");
        let cell = label;
        for (let i = 0; i < 6 && cell; i++) {
            cell.classList.toggle("tier-cell-off", !parentOn);
            cell = cell.nextElementSibling;
        }
        parentOn = on;
    });
    updateTierHint();
}

/* "Keep N/day" is hard-capped by the number of scheduled runs: the schedule
 * cannot produce more archives per day than it has times. */
function updateTierHint() {
    const input = $("tier-d-keep");
    const hint = $("tier-d-hint");
    const runs = Math.max(1, modalTimes.length);
    input.max = runs;
    if ((parseInt(input.value, 10) || 1) > runs)
        input.value = runs;
    hint.textContent = "Maximum " + runs + " per day — one for each scheduled run.";
    hint.hidden = !($("ret-tiered").checked && $("tier-d-on").checked);
}

function openConfigDialog(idx) {
    editingIndex = idx;
    $("config-title").textContent = idx === -1 ? "Add backup" : "Edit backup";
    $("config-name").value = idx === -1 ? "" : (config.backups[idx].title || "");
    $("config-folder").value = idx === -1 ? "" : config.backups[idx].folder;

    // Schedule: one or more daily times
    modalTimes = idx === -1 ? [DEFAULT_TIME] : entryTimesList(config.backups[idx]).slice();
    renderTimesList();
    $("config-new-time").value = DEFAULT_TIME;

    // Retention: simple day-count or tiered (GFS) policy
    const pol = idx !== -1 ? config.backups[idx].retention : null;
    const hasPol = !!(pol && typeof pol === "object");
    $("ret-tiered").checked = hasPol;
    $("ret-simple").checked = !hasPol;
    $("config-retention").value = idx === -1
        ? config.retention_days
        : (config.backups[idx].retention_days || config.retention_days);
    // Sensible daily default: keep as many per day as there are scheduled runs
    setTier("d", hasPol ? pol.daily : { keep: modalTimes.length || 1, days: 7 }, 2, 7, "days");
    setTier("w", hasPol ? pol.weekly : { keep: 1, weeks: 4 }, 1, 4, "weeks");
    setTier("m", hasPol ? pol.monthly : { keep: 1, months: 12 }, 1, 12, "months");
    setTier("y", hasPol ? pol.yearly : null, 1, 5, "years");
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

function tierNum(id, def, max) {
    return Math.min(max, Math.max(1, parseInt($(id).value, 10) || def));
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
    if (!modalTimes.length) {
        showConfigError("Add at least one backup time");
        return;
    }
    const times = modalTimes.slice().sort();

    const tiered = $("ret-tiered").checked;
    let policy = null;
    if (tiered) {
        policy = {};
        if ($("tier-d-on").checked)
            policy.daily = { keep: tierNum("tier-d-keep", 1, Math.max(1, times.length)),
                             days: tierNum("tier-d-span", 7, 90) };
        if ($("tier-w-on").checked)
            policy.weekly = { keep: tierNum("tier-w-keep", 1, 7), weeks: tierNum("tier-w-span", 4, 52) };
        if ($("tier-m-on").checked)
            policy.monthly = { keep: tierNum("tier-m-keep", 1, 10), months: tierNum("tier-m-span", 12, 120) };
        if ($("tier-y-on").checked)
            policy.yearly = { keep: tierNum("tier-y-keep", 1, 12), years: tierNum("tier-y-span", 5, 100) };
        if (!Object.keys(policy).length) {
            showConfigError("Enable at least one retention tier");
            return;
        }
    }

    const useS3 = $("config-storage").value === "s3";
    const incremental = $("config-mode").value === "incremental";
    const fullEvery = Math.max(1, parseInt($("config-full-every").value, 10) || 7);

    const entry = editingIndex === -1 ? { folder } : { ...config.backups[editingIndex], folder };
    entry.times = times;
    delete entry.time;                 // superseded by times[]
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
        consoleWrap.hidden = false;
        consoleOut.textContent = "";
    }

    const args = folder ? [HELPER, "backup", folder] : [HELPER, "backup"];
    const proc = cockpit.spawn(args, { superuser: "require", err: "out" });
    if (consoleOut)
        proc.stream(data => {
            consoleOut.textContent += data;
            consoleOut.scrollTop = consoleOut.scrollHeight;
        });
    proc.then(() => {
        toast("Backup completed", "success");
        refreshArchives().then(render);
    });
    proc.catch(err => {
        if (consoleOut) consoleOut.textContent += "\nError: " + errText(err) + "\n";
        toast("Backup failed", "danger");
    });
    proc.finally(() => setLoading(btn, false));
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
        warn.textContent = deps + " incremental backup" + (deps === 1 ? "" : "s") +
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
        chainNote.textContent = "Incremental archive: the full backup" +
            (item.chain ? " " + item.chain : "") +
            " and every incremental up to this point are restored in order, " +
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

    const proc = cockpit.spawn(args, { superuser: "require", err: "out" });
    restoreProc = proc;
    proc.stream(data => {
        out.textContent += data;
        out.scrollTop = out.scrollHeight;
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
    $("ret-simple").addEventListener("change", updateRetentionPanels);
    $("ret-tiered").addEventListener("change", updateRetentionPanels);
    $("tier-d-keep").addEventListener("input", updateTierHint);
    ["d", "w", "m", "y"].forEach(t =>
        $("tier-" + t + "-on").addEventListener("change", updateTierCascade));
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
    $("backup-console-close").addEventListener("click", () => { $("backup-console").hidden = true; });
    $("refresh-list").addEventListener("click", () => refreshArchives().then(render));

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
        const delay = running.length ? 1500 : 8000;
        setTimeout(() => {
            refreshArchives().then(() => { renderIfChanged(); poll(); });
        }, delay);
    }
    poll();
});
