#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo "install-systemd: root required" >&2; exit 1; }

mode=${1:---dry-run}
src=/opt/server-tools/projects/project-zomboid/systemd
backup_root=/etc/server-tools/projects/project-zomboid/backups
state=/var/lib/server-tools/projects/project-zomboid

case "$mode" in --dry-run|--apply) ;; *) echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2 ;; esac
id steam >/dev/null 2>&1 || { echo "User steam fehlt" >&2; exit 1; }

for unit in zomboid.service zomboid.socket; do
    echo "===== $unit ====="
    if [[ -f "/etc/systemd/system/$unit" ]]; then
        diff -u "/etc/systemd/system/$unit" "$src/$unit" || true
    else
        echo "Noch nicht installiert: /etc/systemd/system/$unit"
    fi
done

if [[ "$mode" == --dry-run ]]; then
    echo
    echo "Dry-run beendet. Anwenden mit: $0 --apply"
    exit 0
fi

stamp=$(date '+%Y-%m-%d_%H-%M-%S')
install -d -o root -g root -m 700 "$backup_root/$stamp"
for unit in zomboid.service zomboid.socket; do
    if [[ -f "/etc/systemd/system/$unit" ]]; then\n        install -o root -g root -m 600 "/etc/systemd/system/$unit" "$backup_root/$stamp/$unit"\n    fi
    install -o root -g root -m 600 "$src/$unit" "/etc/systemd/system/$unit"
done
install -d -o steam -g steam -m 750 "$state"
systemctl daemon-reload
systemctl enable zomboid.service >/dev/null

echo "Unit-Dateien installiert. Kein Dienst wurde automatisch neu gestartet."
echo "Prüfen: systemctl cat zomboid.service zomboid.socket"
echo "Danach kontrolliert neu starten: systemctl restart zomboid.service"
