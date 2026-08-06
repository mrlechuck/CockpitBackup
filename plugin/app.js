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
            backups: [
                { folder: "/etc", time: "02:00", retention_days: 30, enabled: true, title: "System configuration" },
                { folder: "/home/roberto/documents", time: "01:30", retention_days: 14, enabled: true },
                { folder: "/var/www", time: "03:00", retention_days: 30, enabled: false, excludes: ["cache", "*.log"], title: "Web sites" }
            ]
        };
        const now = Math.floor(Date.now() / 1000);
        const mockArchives = [
            { name: "backup-etc-20260807-020000.tar.gz", size: 12400000, mtime: now - 3600 * 7, folder: "/etc" },
            { name: "backup-etc-20260806-020000.tar.gz", size: 12300000, mtime: now - 3600 * 31, folder: "/etc" },
            { name: "backup-home-roberto-documents-20260807-020000.tar.gz", size: 734003200, mtime: now - 3600 * 7, folder: "/home/roberto/documents" },
            { name: "backup-home-roberto-documents-20260806-020000.tar.gz", size: 731906048, mtime: now - 3600 * 31, folder: "/home/roberto/documents" },
            { name: "backup-home-roberto-documents-20260805-020000.tar.gz", size: 729808896, mtime: now - 3600 * 55, folder: "/home/roberto/documents" },
            { name: "backup-var-www-20260807-020000.tar.gz", size: 220043200, mtime: now - 3600 * 7, folder: "/var/www" },
            { name: "backup-20260801-020000.tar.gz", size: 903100000, mtime: now - 3600 * 150, folder: null }
        ];
        function promiseWith(fns) {
            let streamCb = null;
            const p = new Promise(fns.run ? (res, rej) => fns.run(res, rej, d => streamCb && streamCb(d)) : r => r(fns.out || ""));
            p.stream = cb => { streamCb = cb; return p; };
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
                    return promiseWith({ out: JSON.stringify(mockArchives) });
                if (args[1] === "backup")
                    return promiseWith({
                        run: (res, rej, stream) => {
                            const folder = args[2] || "/etc";
                            const lines = ["Backing up " + folder,
                                "  Archive: /var/backups/cockpit-backup/backup-…-20260807-091500.tar.gz",
                                "  Size: 700M", "Removing backups older than retention…", "Done."];
                            let i = 0;
                            const t = setInterval(() => {
                                if (i < lines.length) stream(lines[i++] + "\n");
                                else { clearInterval(t); res(); }
                            }, 350);
                        }
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

function entryTime(b) { return b.time || config.time || DEFAULT_TIME; }

let config = { ...DEFAULT_CONFIG };
let archives = [];
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

function refreshArchives() {
    return cockpit.spawn([HELPER, "list"], { superuser: "try", err: "message" })
        .then(out => {
            try { archives = JSON.parse(out); } catch (e) { archives = []; }
            archivesLoaded = true;
        })
        .catch(err => {
            archives = [];
            archivesLoaded = true;
            toast("Failed to load archives: " + errText(err), "danger");
        });
}

function archivesFor(folder) {
    if (folder === OTHER) {
        const configured = new Set(config.backups.map(b => b.folder));
        return archives.filter(a => !a.folder || !configured.has(a.folder));
    }
    return archives.filter(a => a.folder === folder);
}

/* ---------- List view ---------- */

function renderListView() {
    $("destination").value = config.destination;
    checkTimerEngine();

    $("config-loading").hidden = true;

    const list = $("config-list");
    list.innerHTML = "";

    const countBadge = $("config-count");
    countBadge.hidden = config.backups.length === 0;
    countBadge.textContent = config.backups.length;

    const orphans = archivesLoaded ? archivesFor(OTHER) : [];
    const empty = config.backups.length === 0 && orphans.length === 0;
    $("config-empty").hidden = !empty;
    list.hidden = empty;
    if (empty) return;

    config.backups.forEach((b, idx) => {
        list.appendChild(configRow(b, idx));
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

    const meta = document.createElement("span");
    meta.className = "config-meta muted";
    const parts = [];
    if (b.title) parts.push(b.folder);
    parts.push(b.enabled === false ? "automatic backup off" : "daily at " + entryTime(b));
    parts.push(items.length === 1 ? "1 archive" : items.length + " archives");
    if (items.length) parts.push(formatSize(total));
    parts.push(last ? "last: " + formatAge(last) : "no backups yet");
    parts.push("keeps " + (b.retention_days || config.retention_days) + " days");
    if (b.excludes && b.excludes.length)
        parts.push(b.excludes.length === 1 ? "1 exclusion" : b.excludes.length + " exclusions");
    meta.textContent = parts.join(" · ");

    main.appendChild(path);
    main.appendChild(meta);

    const actions = document.createElement("div");
    actions.className = "config-actions";

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

    const editBtn = document.createElement("button");
    editBtn.className = "btn btn-small";
    editBtn.textContent = "Edit";
    editBtn.addEventListener("click", ev => { ev.stopPropagation(); openConfigDialog(idx); });

    const removeBtn = document.createElement("button");
    removeBtn.className = "btn btn-small";
    removeBtn.textContent = "Remove";
    removeBtn.addEventListener("click", ev => { ev.stopPropagation(); openConfigDeleteDialog(idx); });

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
    meta.textContent = (orphans.length === 1 ? "1 archive" : orphans.length + " archives") +
        " · " + formatSize(total) + " · from folders no longer configured";

    main.appendChild(path);
    main.appendChild(meta);

    const actions = document.createElement("div");
    actions.className = "config-actions";
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

    const items = archivesFor(folder);
    const total = items.reduce((s, a) => s + a.size, 0);
    const parts = [];
    if (entry && entry.title) parts.push(folder);
    if (entry) parts.push(entry.enabled === false ? "automatic backup off" : "daily at " + entryTime(entry));
    parts.push(items.length === 1 ? "1 archive" : items.length + " archives");
    if (items.length) parts.push(formatSize(total) + " total");
    if (entry) parts.push("keeps " + (entry.retention_days || config.retention_days) + " days");
    if (entry && entry.excludes && entry.excludes.length)
        parts.push("excludes: " + entry.excludes.join(", "));
    if (isOther) parts.push("from folders no longer configured");
    $("detail-sub").textContent = parts.join(" · ");

    const countBadge = $("archive-count");
    countBadge.hidden = items.length === 0;
    countBadge.textContent = items.length;

    $("list-empty").hidden = items.length > 0;
    $("list-table-wrap").hidden = items.length === 0;

    const tbody = $("backup-rows");
    tbody.innerHTML = "";
    items.forEach(item => tbody.appendChild(archiveRow(item)));
}

function archiveRow(item) {
    const tr = document.createElement("tr");

    const tdName = document.createElement("td");
    tdName.className = "archive-name";
    tdName.textContent = item.name;

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

    const restoreBtn = document.createElement("button");
    restoreBtn.className = "btn btn-small";
    restoreBtn.textContent = "Restore";
    restoreBtn.addEventListener("click", () => openRestoreDialog(item));

    const deleteBtn = document.createElement("button");
    deleteBtn.className = "btn btn-small btn-danger";
    deleteBtn.textContent = "Delete";
    deleteBtn.addEventListener("click", () => openDeleteDialog(item.name));

    tdActions.appendChild(restoreBtn);
    tdActions.appendChild(deleteBtn);

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

function openConfigDialog(idx) {
    editingIndex = idx;
    $("config-title").textContent = idx === -1 ? "Add backup" : "Edit backup";
    $("config-name").value = idx === -1 ? "" : (config.backups[idx].title || "");
    $("config-folder").value = idx === -1 ? "" : config.backups[idx].folder;
    $("config-time").value = idx === -1 ? DEFAULT_TIME : entryTime(config.backups[idx]);
    $("config-retention").value = idx === -1
        ? config.retention_days
        : (config.backups[idx].retention_days || config.retention_days);
    $("config-excludes").value = idx === -1
        ? ""
        : (config.backups[idx].excludes || []).join("\n");
    $("estimate-result").textContent = "";
    showConfigError(null);
    openModal("config-dialog");
    $("config-folder").focus();
}

function showConfigError(msg) {
    const el = $("config-error");
    el.textContent = msg || "";
    el.hidden = !msg;
}

function saveConfigEntry() {
    const title = $("config-name").value.trim();
    const folder = $("config-folder").value.trim().replace(/\/+$/, "") || $("config-folder").value.trim();
    const time = $("config-time").value || DEFAULT_TIME;
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

    if (editingIndex === -1) {
        const entry = { folder, time, retention_days: retention };
        if (title) entry.title = title;
        if (excludes.length) entry.excludes = excludes;
        config.backups.push(entry);
    } else {
        const entry = { ...config.backups[editingIndex], folder, time, retention_days: retention };
        if (title) entry.title = title;
        else delete entry.title;
        if (excludes.length) entry.excludes = excludes;
        else delete entry.excludes;
        config.backups[editingIndex] = entry;
    }

    const btn = $("config-save");
    setLoading(btn, true);
    saveConfigFile()
        .then(() => {
            closeModal("config-dialog");
            toast(editingIndex === -1 ? "Backup added" : "Backup updated", "success");
            renderListView();
        })
        .catch(err => toast("Failed to save: " + errText(err), "danger"))
        .finally(() => setLoading(btn, false));
}

function toggleEntry(idx, enabled) {
    const entry = config.backups[idx];
    entry.enabled = enabled;
    saveConfigFile()
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
        .then(() => toast("Settings saved", "success"))
        .catch(err => toast("Failed to save: " + errText(err), "danger"))
        .finally(() => setLoading(btn, false));
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

/* ---------- Archive delete ---------- */

function openDeleteDialog(name) {
    deleteArchiveName = name;
    $("delete-archive-name").textContent = name;
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
    openModal("restore-dialog");
}

function updateRestoreMode() {
    const custom = $("mode-custom").checked;
    $("restore-target").disabled = !custom;
    $("restore-warning").hidden = custom;
    if (custom) $("restore-target").focus();
}

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
    proc.stream(data => {
        out.textContent += data;
        out.scrollTop = out.scrollHeight;
    });
    proc.then(() => toast("Restore completed", "success"));
    proc.catch(err => {
        out.textContent += "\nError: " + errText(err) + "\n";
        toast("Restore failed", "danger");
    });
    proc.finally(() => setLoading(btn, false));
}

/* ---------- Init ---------- */

document.addEventListener("DOMContentLoaded", () => {
    // List view
    $("add-config").addEventListener("click", () => openConfigDialog(-1));
    $("config-save").addEventListener("click", saveConfigEntry);
    $("config-folder").addEventListener("keydown", ev => { if (ev.key === "Enter") saveConfigEntry(); });
    $("config-folder").addEventListener("input", () => showConfigError(null));
    $("config-delete-confirm").addEventListener("click", confirmConfigDelete);
    $("estimate-size").addEventListener("click", estimateSize);
    $("save-settings").addEventListener("click", saveSettings);

    // Detail view
    $("back-btn").addEventListener("click", () => goTo(null));
    $("detail-backup-now").addEventListener("click", () => {
        runBackup(currentRoute(), $("detail-backup-now"), $("backup-console"), $("backup-output"));
    });
    $("backup-console-close").addEventListener("click", () => { $("backup-console").hidden = true; });
    $("refresh-list").addEventListener("click", () => refreshArchives().then(render));

    // Modals
    $("restore-confirm").addEventListener("click", doRestore);
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

    window.addEventListener("hashchange", render);

    Promise.all([loadConfig(), refreshArchives()]).then(render);
});
