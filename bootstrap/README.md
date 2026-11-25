# bootstrap

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

## Dateien

- manage-server-tools.sh: Erstinstallation, Status, manueller Sync.
- server-tools-launcher.sh: unabhängiger Starter, lokal installiert unter /usr/local/sbin/server-tools-launcher.
- dispatch.sh: zentral aktualisierbarer Einstiegspunkt.
- setup-mqtt-env.sh: legt fehlende MQTT-Credentials an, ohne bestehende zu überschreiben.

Der Launcher wird nicht automatisch selbst aktualisiert. Scheduler, MQTT-Versand, Logrotation und automatisches Ergänzen bestehender Konfigurationsdateien sind noch nicht implementiert.
