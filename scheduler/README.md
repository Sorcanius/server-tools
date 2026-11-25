# scheduler

Geplanter zentraler Job-Runner.

Das Zielmodell:

- Jobdefinitionen und Zeitpläne liegen zentral im Repository.
- Auf jedem Gerät liegt die lokale Rollen-/Gruppenfreigabe unter `/etc/server-tools/`.
- Nur lokal freigegebene Job-Gruppen dürfen auf dem Gerät ausgeführt werden.
- Persistenter Scheduler-State gehört nach `/var/lib/server-tools/scheduler/`.
- Logs gehören nach `/var/log/server-tools/`.

Der eigentliche Runner und die Jobdefinitionen werden später umgesetzt.
