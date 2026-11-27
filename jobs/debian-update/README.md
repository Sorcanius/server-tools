# debian-update

Generischer Debian-Updatejob. Die Fachlogik enthält bewusst keinen eigenen Sleep/Random-Delay; Zeitplan und Verteilung werden vom server-tools-Scheduler gesteuert.

Standard: täglich 04:00 Uhr mit bis zu 7200 Sekunden zufälligem Delay, also effektiv 04:00-06:00 Uhr nach dem regulären VM/LXC-Backupfenster.

Die bisherige Updatefolge wird zunächst beibehalten: `apt update`, `full-upgrade`, `upgrade`, `dist-upgrade`, `autoremove`.

Während der MQTT-Migration wird der Legacy-Prozess `debianupdate` weiter gesendet und parallel das neue server-tools-Schema veröffentlicht.
