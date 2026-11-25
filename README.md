# server-tools

Zentrale Sammlung von administrativen Shell-Skripten für meine Server, Raspberry Pis und Linux-Systeme.

## Grundprinzip

**GitHub ist die Quelle der Wahrheit.**  
Auf allen Geräten liegt der Checkout unter:

```text
/opt/server-tools
```

Der Ordner ist ausschließlich für versionierte, zentral verwaltete Tools gedacht. Lokale Änderungen sollen dort nicht dauerhaft existieren.

## Verzeichnis-Konventionen

| Zweck | Ort | Beispiel |
|---|---|---|
| Zentral verwaltete Skripte | `/opt/server-tools` | `/opt/server-tools/pihole-dns2mqtt.sh` |
| Systemweite Konfiguration | `/etc` | `/etc/mqtt.env` |
| Credentials / Secrets | `/etc`, restriktive Rechte | `/etc/mqtt.env` mit `chmod 600` |
| Persistente Laufzeitdaten / State | `/var/lib/<tool>` | Checkpoints, Statusdateien |
| Logs | `/var/log` | `/var/log/server-tools-sync.log` |
| Flüchtige Runtime-Dateien | `/run/<tool>` | FIFO, PID, temporäre States |
| Benutzerbezogene Daten | Home-Verzeichnis | nur wenn fachlich sinnvoll |

**Keine lokalen Konfigurationsdateien, Credentials, Logs oder Laufzeitdaten unter `/opt/server-tools` ablegen.**

Die `.gitignore` ist nur ein zusätzlicher Sicherheitsgurt und kein Ablagekonzept für lokale Dateien.

## Skripte ausführen

Die Skripte können direkt aus dem Repository ausgeführt werden:

```bash
sudo /opt/server-tools/pihole-dns2mqtt.sh
```

oder explizit über Bash:

```bash
sudo bash /opt/server-tools/pihole-dns2mqtt.sh
```

Beim Installieren und Synchronisieren setzt `manage-server-tools.sh` für alle `*.sh`-Dateien im Repository das Execute-Bit.

## Erstinstallation auf einem neuen Gerät

Voraussetzung: `git` und `curl`.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Sorcanius/server-tools/main/manage-server-tools.sh \
  | sudo bash -s -- install
```

Danach liegt das Repository unter:

```text
/opt/server-tools
```

## Manueller Sync

```bash
bash /opt/server-tools/manage-server-tools.sh sync
```

Der Sync ist bewusst **destruktiv**:

1. `git fetch --prune origin`
2. `git reset --hard origin/main`
3. `git clean -fd`

Damit werden lokale Änderungen an versionierten Dateien verworfen und nicht ignorierte unversionierte Dateien gelöscht. Ignorierte Dateien werden nicht mit `-x` gelöscht, sollen aber trotzdem nicht im Repository abgelegt werden.

## Automatischer Sync per Cron

Täglich um 03:17 Uhr:

```bash
sudo /opt/server-tools/setup-server-tools-cron.sh daily
```

Oder wöchentlich, sonntags um 03:17 Uhr:

```bash
sudo /opt/server-tools/setup-server-tools-cron.sh weekly
```

Das erzeugt:

```text
/etc/cron.d/server-tools-sync
```

und schreibt die Sync-Ausgabe nach:

```text
/var/log/server-tools-sync.log
```

Prüfen:

```bash
cat /etc/cron.d/server-tools-sync
tail -n 100 /var/log/server-tools-sync.log
```

## MQTT-Credentials

Allgemeine MQTT-Zugangsdaten werden nicht im Repository gespeichert.

Einrichtung:

```bash
sudo /opt/server-tools/setup-mqtt-env.sh
sudo nano /etc/mqtt.env
```

Die Datei:

```text
/etc/mqtt.env
```

enthält ausschließlich die allgemeinen MQTT-Verbindungsdaten. Topics und anwendungsspezifische Einstellungen gehören in das jeweilige ausführende Skript.

## Rollout-Prinzip

Neue Features oder Änderungen werden zentral in GitHub vorgenommen. Geräte mit eingerichtetem Cron-Sync übernehmen die neue Version beim nächsten Lauf automatisch.

Dadurch müssen Skripte nicht auf jedem Gerät manuell kopiert oder angepasst werden.
