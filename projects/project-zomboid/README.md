# project-zomboid

Projektbezogene Verwaltung des Project-Zomboid-Servers.

## Zielstruktur

```text
projects/project-zomboid/
├── README.md
├── systemd/
├── update/
└── tools/
```

## Bestehendes Betriebsmodell, das bei der Migration erhalten werden soll

- Der eigentliche Gameserver läuft als Benutzer `steam`.
- Start/Stop/Restart erfolgt über systemd.
- server-tools darf Updates prüfen, Countdowns auslösen und systemd-Aktionen orchestrieren.
- Beim Serverstart wird der Dedicated Server über SteamCMD aktualisiert/validiert, bevor der Gameserver startet.
- Automatische Update-Restarts sollen nur im bisherigen Wartungsfenster stattfinden und nicht während der regulären Spielzeit.
- Server- und Mod-Updates sollen in denselben kontrollierten Restartpfad einfließen.
- Modupdates werden über den PZ-Konsolenbefehl `checkModsNeedUpdate` erkannt.
- Der Kontroll-FIFO bleibt Teil der systemd-/Serverarchitektur.
- Projektbezogene manuelle Werkzeuge bleiben im Projektordner.

## Lokale Daten

Persistenter State gehört z. B. nach:

```text
/var/lib/server-tools/projects/project-zomboid/
```

Lokale Konfiguration gehört z. B. nach:

```text
/etc/server-tools/projects/project-zomboid/
```

Keine Savegames, Workshopdaten, Server-Binaries oder Credentials gehören ins Repository.

## MQTT

Während der Migration werden bestehende Legacy-Meldungen für die vorhandene Node-RED-Verarbeitung zunächst weiter gesendet. Das neue server-tools-Schema wird parallel ergänzt.

Der bestehende Prozessname `gameserverupdate` bleibt während der Übergangsphase kompatibel erhalten.
