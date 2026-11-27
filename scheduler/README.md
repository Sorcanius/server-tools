# scheduler

Zentrale Jobsteuerung für server-tools.

Der unabhängige server-tools-Launcher wird minütlich aufgerufen. bootstrap/dispatch.sh startet anschließend den Scheduler. Fachliche Jobs bekommen deshalb keine eigenen Cron-Einträge mehr.

Zentrale Definitionen: /opt/server-tools/config/jobs.conf

Lokale Gruppenfreigabe: /etc/server-tools/scheduler/scheduler-groups.conf

Lokale Overrides: /etc/server-tools/scheduler/jobs.local.conf

Alle Gruppen werden bei erstmaligem Auftreten lokal als disabled ergänzt. Dadurch aktiviert eine GitHub-Änderung keine neue Geräte-Rolle automatisch.

## Defaults

- debian-update: 04:00 Uhr, Delay 0-7200 s, Gruppe base.
- mount-check: stündlich, Delay 0-300 s, Gruppe base.
- project-zomboid-update: Minute 55 von 00 bis 16 Uhr, kein Delay, Gruppe project-zomboid.

## Lokale Overrides

Unterstützt werden:

- <job>.enabled=true|false
- <job>.schedule=<5-field cron expression>
- <job>.random_delay=<seconds>
- <job>.timeout=<seconds; 0 = unbegrenzt>
- <job>.user=<local user>

Ein Job-Override aktiviert keine lokal deaktivierte Gruppe.

## Verhalten

- Random-Delay wird pro Ausführung neu bestimmt.
- Catch-up nach Downtime innerhalb eines 24-h-Fensters.
- Überschneidende Läufe desselben Jobs werden per Lock übersprungen.
- Jobs laufen asynchron, damit lange Jobs den minütlichen Launcher nicht blockieren.
- Logs: /var/log/server-tools/jobs/<job>.log
- State: /var/lib/server-tools/scheduler/
