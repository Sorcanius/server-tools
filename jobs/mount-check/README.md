# mount-check

Generischer Mount-Check mit gezieltem Reparaturversuch für zusätzliche Mounts aus `/etc/fstab`. `/` wird nie angefasst.

Die bisherige Semantik bleibt für Node-RED erhalten: Legacy-`process=mountcheck`, Erfolg mit `status="0"`, Fehler mit `1`, `2` oder `3`.

Der Scheduler steuert den stündlichen Lauf und einen Standard-Random-Delay von bis zu 300 Sekunden. Das Script selbst enthält keinen Start-Delay mehr.
