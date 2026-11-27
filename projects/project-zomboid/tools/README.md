# tools

Manuelle Project-Zomboid-Werkzeuge.

Vorgesehen sind mindestens:

- `fix-permissions.sh`: repariert bei Bedarf die Besitzer-/Rechtezuordnung der Zomboid-Verzeichnisse für den Benutzer `steam`.
- `shutdown.sh`: beendet den Gameserver kontrolliert mit Spieler-Countdown und anschließendem systemd-Stop.

Diese Funktionen bleiben bewusst manuell nutzbar und werden nicht automatisch mit dem normalen Updatejob vermischt.
