#!/usr/bin/env bash
set -Eeuo pipefail

# Richtet den regelmäßigen GitHub -> /opt/server-tools Sync per Cron ein.
#
# Standard:
#   sudo /opt/server-tools/bootstrap/setup-server-tools-sync.sh daily
#
# Alternativ:
#   sudo /opt/server-tools/bootstrap/setup-server-tools-sync.sh weekly
#
# Erzeugt:
#   /etc/cron.d/server-tools-sync
#
# Log:
#   /var/log/server-tools-sync.log
#
# Vorhandene Cron-Dateien werden NICHT überschrieben.

CRON_FILE="/etc/cron.d/server-tools-sync"
LOG_FILE="/var/log/server-tools-sync.log"
SYNC_SCRIPT="/opt/server-tools/bootstrap/manage-server-tools.sh"
MODE="${1:-daily}"

if (( EUID != 0 )); then
    echo "FEHLER: Bitte mit sudo/root ausführen." >&2
    exit 1
fi

if [[ -e "$CRON_FILE" ]]; then
    echo "ABBRUCH: $CRON_FILE existiert bereits. Nichts geändert." >&2
    exit 1
fi

if [[ ! -f "$SYNC_SCRIPT" ]]; then
    echo "FEHLER: $SYNC_SCRIPT wurde nicht gefunden." >&2
    exit 1
fi

case "$MODE" in
    daily)
        # Täglich um 03:17 Uhr.
        SCHEDULE="17 3 * * *"
        ;;
    weekly)
        # Sonntags um 03:17 Uhr.
        SCHEDULE="17 3 * * 0"
        ;;
    *)
        echo "FEHLER: Modus muss 'daily' oder 'weekly' sein." >&2
        exit 2
        ;;
esac

cat > "$CRON_FILE" <<EOF
# Automatischer Abgleich von /opt/server-tools mit GitHub.
# GitHub ist die Quelle der Wahrheit; lokale Änderungen im Repository
# werden beim Sync verworfen.
$SCHEDULE root /usr/bin/bash $SYNC_SCRIPT sync >> $LOG_FILE 2>&1
EOF

chown root:root "$CRON_FILE"
chmod 644 "$CRON_FILE"

echo "Cron-Job angelegt: $CRON_FILE"
echo "Modus: $MODE"
echo "Log: $LOG_FILE"
echo
echo "Prüfen mit:"
echo "  cat $CRON_FILE"
echo "  tail -n 100 $LOG_FILE"
