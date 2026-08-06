#!/bin/bash
# Rimuove il plugin "Backup cartelle" da Cockpit.
# NON elimina i backup esistenti né la configurazione.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Esegui come root: sudo ./uninstall.sh" >&2; exit 1; }

systemctl disable --now cockpit-backup.timer 2>/dev/null || true

rm -f /etc/systemd/system/cockpit-backup.service
rm -f /etc/systemd/system/cockpit-backup.timer
rm -rf /etc/systemd/system/cockpit-backup.timer.d
systemctl daemon-reload

rm -rf /usr/share/cockpit/backup
rm -rf /usr/local/libexec/cockpit-backup

echo "Plugin rimosso."
echo "Configurazione conservata in /etc/cockpit-backup/ e i backup nella cartella di destinazione."
echo "Per rimuovere anche quelli: rm -rf /etc/cockpit-backup  (e la cartella dei backup)"
