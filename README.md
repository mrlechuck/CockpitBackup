# Cockpit Backup — plugin backup cartelle

Plugin per [Cockpit](https://cockpit-project.org/) che permette, dall'interfaccia web,
di gestire **un backup separato per ogni cartella**, ognuno col proprio orario:

- **Schermata principale**: elenco dei backup configurati, con aggiunta, modifica
  (cartella, orario, retention) e rimozione delle configurazioni
- **Interruttore per cartella**: ogni backup automatico si attiva o disattiva
  singolarmente, direttamente dalla lista
- **Orario giornaliero per cartella**: ogni configurazione decide quando parte
  il suo backup; i backup persi (server spento) partono al primo controllo utile
- **Pagina di dettaglio** per ogni cartella: archivi con data e dimensione, backup
  manuale con output in tempo reale, restore ed eliminazione
- **Restore** nella posizione originale o in una cartella alternativa
- **Retention per cartella**: giorni di conservazione indipendenti

## Requisiti

- Linux con Cockpit installato (Debian/Ubuntu: `apt install cockpit` — Fedora/RHEL: `dnf install cockpit`)
- `python3`, `tar`, `systemd` (presenti di serie su tutte le distro moderne)

## Installazione

Copia questa cartella sul server Linux, poi:

```bash
sudo ./install.sh
```

Apri Cockpit su `https://<ip-del-server>:9090`, accedi e trova **Backup** nel menu laterale.
Per le operazioni serve la modalità amministrativa (pulsante "Accesso limitato / Turn on
administrative access" in alto).

## Primo utilizzo

1. In **Settings** imposta la cartella di destinazione, poi **Save settings**
2. Clicca **Add backup**: cartella (percorso assoluto), orario giornaliero e giorni di retention
3. Il backup automatico è attivo da subito; puoi disattivarlo con l'interruttore sulla riga
4. (Facoltativo) Entra nel dettaglio della cartella e prova **Backup now**

## Come funziona

| Componente | Percorso |
|---|---|
| Frontend Cockpit | `/usr/share/cockpit/backup/` |
| Script backend | `/usr/local/libexec/cockpit-backup/cockpit-backup.sh` |
| Configurazione | `/etc/cockpit-backup/config.json` |
| Unit systemd | `cockpit-backup.service` + `cockpit-backup.timer` |
| Archivi | `backup-<cartella>-AAAAMMGG-HHMMSS.tar.gz` + sidecar `.meta` |

### Pianificazione per cartella

Il timer systemd si attiva **ogni 10 minuti** ed esegue `backup-due`, che controlla
quali cartelle sono "in scadenza": una cartella è dovuta quando il suo orario
giornaliero è passato e l'archivio più recente è precedente a quell'orario.
In questo modo:

- ogni cartella parte al proprio orario (con al massimo ~10 minuti di ritardo)
- se il server era spento all'orario previsto, il backup parte al primo controllo
  dopo l'avvio (stile anacron)
- un backup manuale conta come backup del giorno: quello automatico non si ripete

Il timer viene abilitato da `install.sh` ed è il motore di tutte le pianificazioni:
l'attivazione/disattivazione per cartella si fa dall'interfaccia (campo `enabled`
nella configurazione). Se il timer non è attivo, la UI mostra un avviso.

### Archivi

Ogni esecuzione crea **un archivio per cartella** (es. `backup-var-www-20260807-020000.tar.gz`).
Accanto a ogni archivio c'è un file `.meta` con il percorso originale, usato dalla UI
per il raggruppamento e per mostrare dove verrà fatto il restore. Gli archivi sono
normali `tar.gz` con percorsi relativi a `/`: ripristinabili anche a mano
(`tar -xzf archivio.tar.gz -C /`), senza dipendere dal plugin.

Se rimuovi una configurazione, i suoi archivi **non** vengono eliminati: restano
visibili nella sezione "Other archives" e sono ancora ripristinabili. La pulizia
retention usa i giorni configurati per ciascuna cartella (default globale per gli
archivi orfani).

### Formato configurazione

```json
{
    "destination": "/var/backups/cockpit-backup",
    "retention_days": 30,
    "backups": [
        { "folder": "/etc", "time": "02:00", "retention_days": 30, "enabled": true },
        { "folder": "/var/www", "time": "03:30", "retention_days": 14, "enabled": false }
    ]
}
```

Il vecchio formato con `"folders": [...]` viene migrato automaticamente al primo salvataggio.

### Uso da riga di comando

```bash
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh backup
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh backup /var/www
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh backup-due
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh list
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh restore backup-var-www-20260807-020000.tar.gz
sudo /usr/local/libexec/cockpit-backup/cockpit-backup.sh restore backup-var-www-20260807-020000.tar.gz /tmp/prova-restore
```

## Disinstallazione

```bash
sudo ./uninstall.sh
```

Configurazione e archivi esistenti **non** vengono eliminati.

## Note

- Il restore nella posizione originale **sovrascrive** i file esistenti (i file creati
  dopo il backup non vengono toccati).
- La destinazione dei backup dovrebbe stare su un disco diverso da quello dei dati
  (o essere sincronizzata altrove) per essere un backup vero.
