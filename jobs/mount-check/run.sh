#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[[ $EUID == 0 ]] || { echo "mount-check: root required" >&2; exit 1; }
source /opt/server-tools/lib/mqtt.sh

FSTAB=/etc/fstab
CHECK_TIMEOUT=5
REPAIR_TIMEOUT=30
RECHECK_WAIT=2
FINAL_RC=0
msg=""
REPAIRED=()
FAILED=()

check_mount() {
    local mountpoint=$1
    mountpoint -q "$mountpoint" || return 1
    timeout "$CHECK_TIMEOUT" stat "$mountpoint" >/dev/null 2>&1 || return 2
    return 0
}

repair_mount() {
    local mountpoint=$1 current_rc=$2 unit
    echo "Reparaturversuch: $mountpoint"
    if (( current_rc == 1 )); then
        timeout "$REPAIR_TIMEOUT" mount "$mountpoint" >/dev/null 2>&1
        return $?
    fi
    if (( current_rc == 2 )); then
        unit=$(systemd-escape --path --suffix=mount "$mountpoint")
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        timeout "$REPAIR_TIMEOUT" systemctl restart "$unit" >/dev/null 2>&1
        return $?
    fi
    return 1
}

mapfile -t MOUNTPOINTS < <(
    findmnt --fstab --noheadings --raw --output TARGET | while IFS= read -r target; do
        [[ -n "$target" && "$target" != / && "$target" != none ]] || continue
        printf '%s\n' "$target"
    done
)

if [[ ! -r "$FSTAB" ]]; then
    FINAL_RC=3
    msg="UNKNOWN: $FSTAB nicht lesbar"
elif (( ${#MOUNTPOINTS[@]} == 0 )); then
    FINAL_RC=3
    msg="UNKNOWN: Keine zu prüfenden Mountpoints in $FSTAB gefunden"
else
    for MOUNTPOINT in "${MOUNTPOINTS[@]}"; do
        echo "Prüfe: $MOUNTPOINT"
        set +e
        check_mount "$MOUNTPOINT"
        RC=$?
        set -e
        if (( RC == 0 )); then
            echo "  OK"
            continue
        fi
        (( RC == 1 )) && echo "  FEHLER: nicht gemountet" || echo "  FEHLER: Mount hängt oder ist nicht erreichbar"
        set +e
        repair_mount "$MOUNTPOINT" "$RC"
        set -e
        sleep "$RECHECK_WAIT"
        set +e
        check_mount "$MOUNTPOINT"
        AFTER_RC=$?
        set -e
        if (( AFTER_RC == 0 )); then
            echo "  OK: Reparatur erfolgreich"
            REPAIRED+=("$MOUNTPOINT")
        else
            echo "  CRITICAL: Reparatur fehlgeschlagen"
            FAILED+=("$MOUNTPOINT")
            (( AFTER_RC > FINAL_RC )) && FINAL_RC=$AFTER_RC
        fi
    done

    if (( ${#FAILED[@]} == 0 )); then
        FINAL_RC=0
        if (( ${#REPAIRED[@]} == 0 )); then
            msg="OK: Alle Mountpoints gemountet und erreichbar"
        else
            REPAIRED_TEXT=$(IFS=', '; echo "${REPAIRED[*]}")
            msg="OK: Mountpoints repariert: $REPAIRED_TEXT"
        fi
    else
        FAILED_TEXT=$(IFS=', '; echo "${FAILED[*]}")
        case "$FINAL_RC" in
            1) msg="CRITICAL: Mountpoints nicht gemountet: $FAILED_TEXT" ;;
            2) msg="CRITICAL: Mountpoints hängen oder sind nicht erreichbar: $FAILED_TEXT" ;;
            *) FINAL_RC=3; msg="UNKNOWN: Fehler bei Mountpoints: $FAILED_TEXT" ;;
        esac
    fi
fi

echo "$msg"
repaired_json=$(printf '%s\n' "${REPAIRED[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')
failed_json=$(printf '%s\n' "${FAILED[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')
details=$(jq -cn --argjson repaired "$repaired_json" --argjson failed "$failed_json" --argjson legacy_status "$FINAL_RC" '{repaired:$repaired,failed:$failed,legacy_status:$legacy_status}')

if (( FINAL_RC == 0 )); then
    category=success
else
    category=error
fi
mqtt_publish_both "mountcheck" "$FINAL_RC" "$category" "mount-check" "$msg" "$FINAL_RC" "" "$details"
exit "$FINAL_RC"
