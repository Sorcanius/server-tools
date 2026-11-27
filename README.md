# server-tools

Zentrale administrative Skripte für Debian-basierte Linux-Systeme.

## Erstinstallation (Debian, Raspberry Pi OS, Proxmox/LXC)

Bei einem öffentlichen Repository als root ausführen:

```bash
apt-get update && apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/Sorcanius/server-tools/main/bootstrap/manage-server-tools.sh -o /tmp/manage-server-tools.sh
bash /tmp/manage-server-tools.sh install
```

Bei einem privaten Repository [manage-server-tools.sh](https://github.com/Sorcanius/server-tools/blob/main/bootstrap/manage-server-tools.sh) im angemeldeten Browser als Raw-Datei herunterladen, auf das Zielgerät nach /tmp/manage-server-tools.sh übertragen und als root mit dem letzten Befehl starten.

Der Installer prüft anonymen HTTPS-Zugriff. Ist er möglich, stehen HTTPS (Standard, ohne Credentials) und SSH zur Auswahl. Andernfalls kann SSH eingerichtet werden; ein fehlgeschlagener HTTPS-Test beweist nicht, dass das Repository privat ist.

Für SSH den angezeigten öffentlichen Schlüssel unter [Settings → Deploy keys](https://github.com/Sorcanius/server-tools/settings/keys) hinzufügen, Gerätenamen als Titel verwenden, **Allow write access deaktiviert lassen** und im Terminal Enter drücken.

Der Modus steht lokal unter /etc/server-tools/config/github.conf. Ein Wechsel erfolgt ausschließlich ausdrücklich:

```bash
sudo /opt/server-tools/bootstrap/manage-server-tools.sh auth ssh
sudo /opt/server-tools/bootstrap/manage-server-tools.sh auth https
```

SSH funktioniert für Public und Private. HTTPS funktioniert nur bei anonym erreichbarem Repository. Bei einem Wechsel zu Private müssen HTTPS-Clients vorher auf SSH umgestellt werden. Es gibt keinen automatischen Fallback bei Authentifizierungsfehlern.

Der private Schlüssel liegt unter /etc/server-tools/credentials/github.key (root:root, 600). Nur github.key.pub an GitHub übertragen. Der GitHub-Hostschlüssel wird fest hinterlegt; unbekannte oder geänderte Hostschlüssel werden nicht akzeptiert. Bei legitimer Rotation muss github_known_hosts nach Prüfung lokal aktualisiert werden.

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
- scheduler/: zentrale Jobsteuerung und Zeitpläne
- jobs/: generische periodische Aufgaben
- projects/: zusammengehörige, projektspezifische Komponenten
- services/: generische dauerhafte Dienste
- tools/: generische manuelle Werkzeuge
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

## Stand

Scheduler-Basis, Dual-MQTT, Debian-Update, Mount-Check und die erste Project-Zomboid-Migration sind implementiert und für kontrollierte Tests vorgesehen.

Neue Job-Gruppen werden lokal immer als deaktiviert angelegt. Erst ein lokales Opt-in unter /etc/server-tools/scheduler/scheduler-groups.conf aktiviert Jobs auf einem Gerät.

Noch nicht vollständig umgesetzt sind unter anderem allgemeiner Vorlagenabgleich, die geplante zentrale Logrotation, Health-Checks und die spätere automatisierte Bereinigung der Altinstallationen. Siehe MIGRATION.md.


## Strukturregeln

Generische Funktionen, die auf vielen Systemen eingesetzt werden, bleiben in den allgemeinen Bereichen:

- `jobs/` für periodische Aufgaben wie Debian-Update oder Mount-Check.
- `tools/` für manuelle, systemunabhängige Werkzeuge wie Festplattenprüfungen.
- `services/` für generische dauerhaft laufende Dienste.

Geschlossene Systeme werden projektbezogen zusammengehalten:

```text
projects/<projekt>/
├── README.md
├── systemd/
├── update/
└── tools/
```

Projektbezogene Tools gehören in `projects/<projekt>/tools/`; generische Tools in `tools/`.

Dauerhafte Dienste werden weiterhin von systemd betrieben. server-tools versioniert und verteilt Unit-Dateien, orchestriert Updates/Start/Stop/Restart und führt periodische Jobs aus, ersetzt systemd aber nicht.

## Scheduler-Grundsätze

Cron startet nur den server-tools-Framework-Launcher. Fachliche Jobs werden nicht dauerhaft als eigene Cron-Einträge gepflegt.

Zeitpläne und Standard-Delays liegen zentral im Repository. Lokale Geräte dürfen definierte Werte unter `/etc/server-tools/scheduler/` überschreiben. Die lokale Konfiguration entscheidet außerdem, welche Job-Gruppen ein Gerät akzeptiert.

Aktuelle zentrale Defaults:

- Debian-Update: täglich 04:00 Uhr, zufälliger Delay bis 7200 s; dadurch effektiver Start zwischen 04:00 und 06:00 Uhr.
- Mount-Check: stündlich, zufälliger Delay bis 300 s.
- Project-Zomboid-Update: Wartungsfenster entsprechend dem bisherigen Betrieb; automatische Restarts nicht während der regulären Spielzeit.

Random-Delays gehören in Scheduler-/Konfiguration und nicht in die Fachskripte.

## MQTT-Migration

Bestehende produktive MQTT-Verträge werden während der Migration zunächst parallel weiter bedient. Das neue server-tools-Schema wird zusätzlich veröffentlicht, bis Node-RED vollständig umgestellt und geprüft ist.

Die lokale Credential-Datei soll zwei unabhängige Credential-Sätze unterstützen:

- Legacy-MQTT für die bestehende Node-RED-Verarbeitung.
- Neues server-tools-MQTT für das neue Schema.

Keine echten Zugangsdaten gehören ins Repository. Das Umschalten erfolgt erst nach erfolgreichem Parallelbetrieb.
