# scheduler

Zentrale Jobsteuerung für server-tools.

## Zielmodell

- Fachliche Jobs werden nicht über eigene Cron-Einträge auf jedem Gerät geplant.
- Cron startet ausschließlich den server-tools-Framework-Launcher.
- Jobdefinitionen, Standardzeiten und Standard-Delays liegen zentral im Repository.
- Lokale Overrides liegen außerhalb des Checkouts unter `/etc/server-tools/scheduler/`.
- Das Gerät entscheidet lokal, welche Job-Gruppen es akzeptiert.
- Neue Gruppen werden dadurch nicht allein durch eine GitHub-Änderung auf einem Gerät aktiviert.
- Neue oder geänderte Jobs innerhalb einer lokal freigegebenen Gruppe dürfen zentral ausgerollt werden.
- Persistenter Scheduler-State gehört nach `/var/lib/server-tools/scheduler/`.
- Logs gehören nach `/var/log/server-tools/`.

## Konfigurationspriorität

```text
zentrale Jobdefinition
        ↓
lokaler Override
        ↓
effektive Jobkonfiguration
```

Lokale Overrides dürfen insbesondere `enabled`, `schedule`, `random_delay` und definierte Laufzeitparameter anpassen. Scriptpfade, Integritätsregeln und zentrale Sicherheitsvorgaben sollen nicht lokal umgebogen werden.

## Random-Delay

Random-Delays werden vom Scheduler pro Ausführung neu berechnet. Dadurch starten viele Geräte nicht gleichzeitig dieselbe Aufgabe.

Geplante Defaults:

```yaml
debian-update:
  schedule: "0 4 * * *"
  random_delay: 7200

mount-check:
  schedule: "0 * * * *"
  random_delay: 300
```

Damit verteilt sich Debian-Update standardmäßig auf 04:00-06:00 Uhr. Das liegt nach dem regulären VM/LXC-Backupfenster von 02:00-04:00 Uhr.

Der Scheduler selbst ist noch nicht vollständig implementiert.
