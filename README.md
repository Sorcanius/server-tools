# server-tools

Zentrale Sammlung von administrativen Skripten für Server, Raspberry Pis und Linux-Systeme.

## Grundprinzip

**GitHub ist die Quelle der Wahrheit für `/opt/server-tools`.**

Auf allen Geräten liegt der Checkout unter:

```text
/opt/server-tools
```

Lokale Konfiguration, Credentials, Logs und Laufzeitdaten liegen bewusst außerhalb des Repositories.

## Struktur

```text
server-tools/
├── README.md
├── .gitignore
├── bootstrap/    Installation und Verwaltung von server-tools selbst
├── scheduler/    zentrale Jobsteuerung; lokale Freigaben bleiben auf dem Gerät
├── jobs/         periodische Aufgaben, die starten und wieder enden
├── services/     dauerhaft laufende Komponenten
├── tools/        manuell gestartete Werkzeuge
└── lib/          gemeinsam verwendete Funktionen
```

**Regel:** Die erste Ebene beschreibt den Lebenszyklus, darunter liegt die konkrete Funktion als eigene Komponente.

## Lokale Daten

| Zweck | Ort |
|---|---|
| Gerätekonfiguration / Rollen | `/etc/server-tools/` |
| Allgemeine MQTT-Credentials | `/etc/mqtt.env` |
| Persistenter State | `/var/lib/server-tools/` |
| Logs | `/var/log/server-tools/` bzw. fachlich passender Logpfad |
| Flüchtige Runtime-Dateien | `/run/server-tools/` |

Keine lokalen Konfigurationsdateien, Credentials, Logs oder Laufzeitdaten unter `/opt/server-tools` ablegen.

Die `.gitignore` ist nur ein zusätzlicher Sicherheitsgurt.

## Erstinstallation

Voraussetzung: `git` und `curl`.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Sorcanius/server-tools/main/bootstrap/manage-server-tools.sh \
  | sudo bash -s -- install
```

## Manueller Sync

```bash
bash /opt/server-tools/bootstrap/manage-server-tools.sh sync
```

Der Sync ist bewusst destruktiv:

1. `git fetch --prune origin`
2. `git reset --hard origin/main`
3. `git clean -fd`

Lokale Änderungen im Repository werden verworfen.

## Automatischer Sync

Täglich:

```bash
sudo /opt/server-tools/bootstrap/setup-server-tools-sync.sh daily
```

Wöchentlich:

```bash
sudo /opt/server-tools/bootstrap/setup-server-tools-sync.sh weekly
```

Cron-Datei:

```text
/etc/cron.d/server-tools-sync
```

Log:

```text
/var/log/server-tools-sync.log
```

## MQTT-Credentials

```bash
sudo /opt/server-tools/bootstrap/setup-mqtt-env.sh
sudo nano /etc/mqtt.env
```

Topics und anwendungsspezifische Einstellungen gehören in die jeweilige Komponente, nicht in die globale Credential-Datei.

## Ausführung

Skripte werden direkt aus `/opt/server-tools` aufgerufen und nicht an andere Orte kopiert.

Beispiele:

```bash
sudo /opt/server-tools/services/pihole-dns2mqtt/pihole-dns2mqtt.sh
sudo /opt/server-tools/tools/pi-usb-disk-check/pi-usb-disk-check.sh
```

Beim Installieren und Synchronisieren werden `*.sh`-Dateien rekursiv ausführbar gemacht.

## Scheduler-Modell

Der Scheduler wird separat umgesetzt. Vorgesehen ist:

- GitHub enthält Jobdefinitionen, Code und Zeitpläne.
- Das Gerät legt lokal unter `/etc/server-tools/` fest, welche Job-Gruppen es akzeptiert.
- GitHub kann dadurch keine neue Geräte-Rolle aktivieren; das Gerät optiert lokal in Gruppen ein.
