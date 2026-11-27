# project-zomboid

Zusammengehörige Verwaltungslogik für den Project-Zomboid-Server.

## Struktur

- config.conf – zentrale, nicht geheime Projektpfade/-werte.
- lib/common.sh – Control-FIFO, Countdown und Manifestabfrage.
- service/start-server.sh – SteamCMD-Update/Validate und Gameserverstart.
- service/steam-update.txt – SteamCMD-Runscript.
- systemd/ – versionierte zomboid.service und zomboid.socket.
- update/check-update.sh – kombinierter Server-/Modupdatecheck.
- tools/fix-permissions.sh – manuelle Rechtekorrektur.
- tools/shutdown.sh – manueller 5-Minuten-Shutdown.
- tools/install-systemd.sh – Dry-Run/Installation der Unit-Dateien.

## Betrieb

Der Gameserver läuft weiterhin als steam. systemd betreibt Start/Stop/Restart und den Control-FIFO. server-tools orchestriert Updateprüfung und kontrollierte Aktionen.

Jeder normale Serverstart führt zuerst SteamCMD app_update 380870 validate aus. Danach wird der aktuelle Online-Manifeststand unter /var/lib/server-tools/projects/project-zomboid/server-manifest gespeichert.

## Updatecheck

Der Schedulerjob project-zomboid-update läuft standardmäßig stündlich um Minute 55 von 00 bis 16 Uhr. Damit erfolgen automatische Restarts nicht in der regulären Spielzeit.

Geprüft werden:

1. Dedicated-Server-Manifest.
2. Workshop-Modstatus über checkModsNeedUpdate.
3. gemeinsamer Restartpfad bei Server- und/oder Modupdate.

Ein manuell gestoppter Dienst wird nicht automatisch gestartet.

## Test/Migration

Zuerst Unit-Diff prüfen:

sudo /opt/server-tools/projects/project-zomboid/tools/install-systemd.sh --dry-run

Dann kontrolliert anwenden:

sudo /opt/server-tools/projects/project-zomboid/tools/install-systemd.sh --apply

Vorhandene Units werden unter /etc/server-tools/projects/project-zomboid/backups/<timestamp>/ gesichert. Das Installationsscript startet den Gameserver nicht automatisch neu.

Scheduler lokal aktivieren über /etc/server-tools/scheduler/scheduler-groups.conf:

project-zomboid=enabled

Während der Migration bleibt process=gameserverupdate auf dem Legacy-MQTT-Pfad erhalten und das neue server-tools-Schema wird parallel gesendet.
