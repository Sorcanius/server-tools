# Migration / Rollout-Checkliste

Die neuen Jobs werden zunächst parallel zu bestehenden Installationen getestet. Altlasten werden erst nach positiven Tests und beim beginnenden Rollout entfernt.

## Vor Cleanup prüfen

- Scheduler läuft zuverlässig und gewünschte Gruppen sind lokal freigegeben.
- Debian-Update und Mount-Check wurden mindestens einmal erfolgreich über server-tools ausgeführt.
- Project-Zomboid-Updatecheck erkennt Server- und Modupdates wie erwartet.
- Legacy-MQTT erreicht die bestehende Node-RED-Verarbeitung weiterhin.
- Neues MQTT-Schema wird parallel korrekt empfangen.
- systemd-Units wurden per Dry-Run und anschließend kontrolliert geprüft.

## Später automatisierbare Altlasten

Erst danach können kontrolliert entfernt werden:

- alte fachliche Cron-Einträge,
- /opt/DebUpdate.h,
- /opt/mountcheck.sh,
- /opt/send2mqtt.sh,
- alte projektspezifische Zomboid-Helfer unter /mnt/steamcmd, soweit vollständig ersetzt.

Die Bereinigung soll als eigener Migrationsschritt mit Bestandsprüfung/Dry-Run umgesetzt werden; sie ist noch nicht aktiv.
