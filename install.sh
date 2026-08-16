#!/bin/bash
# Installa il plugin "Backup cartelle" per Cockpit.
# Eseguire come root sulla macchina Linux: sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Esegui come root: sudo ./install.sh" >&2; exit 1; }

command -v python3 >/dev/null || { echo "python3 è richiesto ma non è installato" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar è richiesto ma non è installato" >&2; exit 1; }
# Optional but worth it on multi-core boards: parallel gzip for backups,
# consolidation and restores (auto-detected at runtime)
command -v pigz >/dev/null || echo "Suggerimento: 'apt install pigz' rende compressione/decompressione ~4x più veloci (opzionale)"
[ -d /usr/share/cockpit ] || { echo "Cockpit non sembra installato (/usr/share/cockpit mancante)" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"

PLUGIN_DIR=/usr/share/cockpit/backup
HELPER_DIR=/usr/local/libexec/cockpit-backup
CONFIG_DIR=/etc/cockpit-backup

echo "Installo il frontend in $PLUGIN_DIR …"
mkdir -p "$PLUGIN_DIR"
cp "$SRC"/plugin/manifest.json "$SRC"/plugin/index.html "$SRC"/plugin/app.js "$SRC"/plugin/style.css "$SRC"/plugin/app-icon.svg "$PLUGIN_DIR/"

echo "Installo lo script di backup in $HELPER_DIR …"
mkdir -p "$HELPER_DIR"
install -m 0755 "$SRC/backend/cockpit-backup.sh" "$HELPER_DIR/cockpit-backup.sh"

echo "Installo le unit systemd…"
install -m 0644 "$SRC/backend/cockpit-backup.service" /etc/systemd/system/cockpit-backup.service
install -m 0644 "$SRC/backend/cockpit-backup.timer" /etc/systemd/system/cockpit-backup.timer

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    echo "Creo la configurazione iniziale in $CONFIG_DIR/config.json …"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.json" <<'EOF'
{
    "destination": "/var/backups/cockpit-backup",
    "retention_days": 30,
    "backups": []
}
EOF
    chmod 0600 "$CONFIG_DIR/config.json"
else
    echo "Configurazione esistente trovata, la lascio invariata."
fi

systemctl daemon-reload
# The timer is the engine for per-folder schedules: always on
systemctl enable --now cockpit-backup.timer
# Generate the OnCalendar entries from the current configuration
"$HELPER_DIR/cockpit-backup.sh" apply-schedule

echo
echo "Installazione completata."
echo "Apri Cockpit (https://<server>:9090) e trova 'Backup' nel menu."
echo "Aggiungi le cartelle dall'interfaccia: ognuna ha il suo orario e il suo"
echo "interruttore di attivazione."
