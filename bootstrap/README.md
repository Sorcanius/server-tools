# bootstrap

## Erstinstallation (Debian, Raspberry Pi OS, Proxmox/LXC)

1. Bei GitHub anmelden und [manage-server-tools.sh](https://github.com/Sorcanius/server-tools/blob/main/bootstrap/manage-server-tools.sh) herunterladen (Raw-Datei).
2. Die Datei beispielsweise per SCP nach /tmp/manage-server-tools.sh auf das Zielgerät übertragen.
3. Als root ausführen:

```bash
bash /tmp/manage-server-tools.sh install
```

4. Falls der GitHub-Zugriff noch nicht eingerichtet ist, zeigt der Installer den öffentlichen SSH-Schlüssel an. Diesen unter [Settings → Deploy keys](https://github.com/Sorcanius/server-tools/settings/keys) hinzufügen. Als Titel den Gerätenamen verwenden. **Allow write access nicht aktivieren.**
5. Im Terminal Enter drücken. Der Installer prüft den Zugriff und setzt die Installation fort.

Bei einem öffentlichen Repository ist alternativ ein direkter Download möglich:

```bash
apt-get update && apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/Sorcanius/server-tools/main/bootstrap/manage-server-tools.sh -o /tmp/manage-server-tools.sh
bash /tmp/manage-server-tools.sh install
```

Auch bei öffentlichen Repositories erfolgt der anschließende Git-Zugriff ausschließlich per SSH mit Deploy Key. Public/Private kann daher ohne Client-Änderung gewechselt werden.

Der private Schlüssel liegt unter /etc/server-tools/credentials/github.key (root:root, 600). Nur github.key.pub an GitHub übertragen. Der Hostschlüssel wird aus der offiziellen GitHub-Dokumentation fest hinterlegt; unbekannte oder geänderte Hostschlüssel werden nicht automatisch akzeptiert. Bei einer legitimen Hostschlüsselrotation muss github_known_hosts nach Prüfung lokal aktualisiert werden.

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
