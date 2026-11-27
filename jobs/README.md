# jobs

Generische periodische Aufgaben, die auf mehreren Systemen eingesetzt werden.

Aktuell:

- debian-update/ – Debian-Updates mit Legacy- und neuem MQTT-Event.
- mount-check/ – Mountprüfung und gezielte Reparatur mit Legacy- und neuem MQTT-Event.

Zeitplan und Random-Delay stehen zentral in config/jobs.conf und können lokal über /etc/server-tools/scheduler/jobs.local.conf angepasst werden. Die Fachskripte enthalten keinen eigenen Start-Delay.

Geschlossene projektspezifische Systeme gehören nach projects/<projekt>/.
