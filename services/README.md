# services

Generische dauerhaft laufende Komponenten.

Dauerhafte Prozesse werden weiterhin von systemd betrieben. server-tools kann Unit-Dateien versionieren, installieren und kontrollierte Start-/Stop-/Restart-Aktionen auslösen, ersetzt systemd jedoch nicht.

Projektbezogene Services und ihre Unit-Dateien bleiben möglichst im jeweiligen Projekt unter `projects/<projekt>/systemd/`.
