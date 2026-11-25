# server-tools

Zentrale administrative Skripte für Debian-basierte Linux-Systeme.

## Erstinstallation (Debian, Raspberry Pi OS, Proxmox/LXC)

Als root auf einem frischen System ausführen:

```bash
apt-get update && apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/Sorcanius/server-tools/main/bootstrap/manage-server-tools.sh -o /tmp/manage-server-tools.sh
bash /tmp/manage-server-tools.sh install
```

Die Installation richtet Grundpakete, Systembenutzer, Verzeichnisse, Checkout, Launcher und Cron ein.

MQTT-Zugangsdaten anschließend lokal bearbeiten:

```bash
nano /etc/server-tools/credentials/mqtt.env
```

Status und manueller Sync:

```bash
bash /opt/server-tools/bootstrap/manage-server-tools.sh status
bash /opt/server-tools/bootstrap/manage-server-tools.sh sync
cat /etc/cron.d/server-tools
tail -n 50 /var/log/server-tools/launcher.log
```

## Architektur

GitHub main ist die alleinige Source of Truth für /opt/server-tools. Lokale Änderungen und unversionierte Dateien (auch ignorierte Dateien und verschachtelte unversionierte Git-Repositories) werden beim Sync verworfen. Niemals lokale Daten im Checkout speichern.

Root besitzt den Code, normale Benutzer dürfen lesen und ausführbare Dateien starten. Git verwaltet das Executable-Bit. Der Systembenutzer server-tools erhält bevorzugt UID/GID 621, sonst das nächste freie Paar bis 999, ohne Login.

- bootstrap/: Installation und Verwaltung
- scheduler/: Gruppensteuerung
- jobs/: periodische Aufgaben
- services/: dauerhafte Dienste
- tools/: manuelle Werkzeuge
- lib/: gemeinsame Bibliotheken
- config/: zentrale Standardwerte

Lokale Pfade:
- /etc/server-tools/credentials/ — Zugangsdaten
- /etc/server-tools/config/ — lokale Overrides
- /etc/server-tools/scheduler/ — lokale Gruppenfreigaben
- /var/lib/server-tools/ — persistenter State
- /var/log/server-tools/ — Logs
- /run/server-tools/ — flüchtige Sperren

Cron ruft /usr/local/sbin/server-tools-launcher minütlich als root auf. Dieser unabhängige Launcher synchronisiert main standardmäßig alle 3600 Sekunden und startet bootstrap/dispatch.sh. Lokale Sync-Einstellungen haben Vorrang. Der Launcher aktualisiert sich nicht selbst. Unsichere oder unbekannte Checkouts werden nicht automatisch gelöscht.

## Stand und geplante Funktionen

Die Basisinstallation implementiert noch keinen MQTT-Versand, Scheduler, Vorlagenabgleich oder Logrotation. Keine Jobs sind aktiviert.

Zentrale Standards mit lokalen Overrides; Gruppen lokal opt-in, Skripte mehrfach zuordenbar, lokale Ausschlüsse möglich. Neue Gruppen deaktiviert, neue Optionen auskommentiert ergänzen, bestehende Credentials erhalten. Framework-Abhängigkeiten automatisch installieren, skriptspezifische nur melden. Health-Checks rein diagnostisch. MQTT-Basis /home/device/server-tools, Kategorien critical/error/warning/success/heartbeat, Hostname am Ende, QoS 1, Heartbeat 300 Sekunden, Puffer letzte 10 Nachrichten maximal sechs Stunden. JSON: schema_version, event_id, system, service, details. Logs 30 Tage, 10 MB pro Datei, 250 MB gesamt. Skript-Locks, gemeinsamer Repository-Lock, Standardtimeout 30 Minuten, Überschneidungen standardmäßig überspringen.
