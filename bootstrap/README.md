# bootstrap

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

## Dateien

- manage-server-tools.sh: Erstinstallation, Status, manueller Sync.
- server-tools-launcher.sh: unabhängiger Starter, lokal installiert unter /usr/local/sbin/server-tools-launcher.
- dispatch.sh: zentral aktualisierbarer Einstiegspunkt.
- setup-mqtt-env.sh: legt fehlende MQTT-Credentials an, ohne bestehende zu überschreiben.

Der Launcher wird nicht automatisch selbst aktualisiert. Scheduler, MQTT-Versand, Logrotation und automatisches Ergänzen bestehender Konfigurationsdateien sind noch nicht implementiert.
