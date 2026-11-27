# update

Update- und Restartlogik für Project Zomboid.

Geplante Funktionen:

- Dedicated-Server-Version prüfen.
- Modstatus über `checkModsNeedUpdate` prüfen.
- Server- und Modupdate als gemeinsame Restartgründe behandeln.
- nur einen kontrollierten Restart auslösen, auch wenn mehrere Gründe gleichzeitig vorliegen.
- das bestehende Wartungsfenster beibehalten, damit während der regulären Spielzeit kein automatischer Restart erfolgt.
- State nach `/var/lib/server-tools/projects/project-zomboid/` schreiben.
- Zeitplan und Delays über den zentralen Scheduler konfigurieren, nicht im Fachskript.
