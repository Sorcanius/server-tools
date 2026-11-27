# projects

Geschlossene, zusammengehörige Systeme werden projektbezogen in einem gemeinsamen Ordner gehalten.

Beispiel:

```text
projects/project-zomboid/
├── README.md
├── systemd/
├── update/
└── tools/
```

Regeln:

- Projektspezifische Unit-Dateien, Update-Logik und manuelle Tools bleiben beim Projekt.
- Generische Funktionen, die auf vielen Systemen verwendet werden, gehören weiterhin nach `jobs/`, `services/` oder `tools/`.
- Lokale Konfiguration, Credentials, State und Logs liegen außerhalb des Git-Checkouts unter `/etc/server-tools/`, `/var/lib/server-tools/` und `/var/log/server-tools/`.
