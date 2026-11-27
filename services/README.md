# services

Generische dauerhaft laufende Komponenten.

Dauerhafte Prozesse werden weiterhin von systemd betrieben. server-tools kann Unit-Dateien versionieren, installieren und kontrollierte Start-/Stop-/Restart-Aktionen auslösen, ersetzt systemd jedoch nicht.

Projektbezogene Services und ihre Unit-Dateien bleiben möglichst im jeweiligen Projekt unter `projects/<projekt>/systemd/`.


Nicht privilegierte generische Services sollen standardmäßig als `server-tools` laufen. Nur wenn ein Dienst zwingend eigene Rechte oder ein anwendungsspezifisches Konto benötigt, wird davon abgewichen.

Beispiel für eine bewusste Ausnahme: Project Zomboid bleibt beim eigenen Benutzer `steam`.
