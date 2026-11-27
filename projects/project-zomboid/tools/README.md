# tools

Manuelle Project-Zomboid-Werkzeuge:

- fix-permissions.sh – setzt /home/steam/Zomboid und /mnt/steamcmd/pzserver2 rekursiv auf steam:steam, falls Kopier-/Berechtigungsprobleme aufgetreten sind.
- shutdown.sh – kontrollierter 5-Minuten-Countdown und anschließend systemctl stop zomboid.service.
- install-systemd.sh – vergleicht/installiert die versionierten Unit-Dateien; Standard ist Dry-Run.
