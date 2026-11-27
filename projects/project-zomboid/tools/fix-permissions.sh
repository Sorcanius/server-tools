#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo "fix-permissions: root required" >&2; exit 1; }

for path in /home/steam/Zomboid /mnt/steamcmd/pzserver2; do
    if [[ -e "$path" ]]; then
        echo "Setze steam:steam rekursiv auf $path"
        chown -R steam:steam "$path"
    else
        echo "WARNUNG: nicht vorhanden: $path" >&2
    fi
done
