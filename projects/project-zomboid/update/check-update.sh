#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[[ $EUID == 0 ]] || { echo "project-zomboid update: root required" >&2; exit 1; }
CHECK_ONLY=false
case "${1:-}" in
    "") ;;
    --check-only) CHECK_ONLY=true ;;
    *) echo "Usage: $0 [--check-only]" >&2; exit 2 ;;
esac
source /opt/server-tools/projects/project-zomboid/lib/common.sh
source /opt/server-tools/lib/mqtt.sh

install -d -o root -g root -m 755 "$(dirname "$PZ_STATE_DIR")"
if [[ ! -d "$PZ_STATE_DIR" ]]; then
    install -d -o steam -g steam -m 750 "$PZ_STATE_DIR"
fi

online=$(pz_online_manifest 2>/dev/null || true)
if [[ ! "$online" =~ ^[0-9]+$ ]]; then
    err="Fehler bei der Abfrage der aktuellen ProjectZomboid-Version"
    echo "$err" >&2
    mqtt_publish_both "gameserverupdate" "failure" "error" "project-zomboid" "Upgrade-Prüfung fehlgeschlagen" 1 "$err" '{"update_type":"server"}'
    exit 1
fi

state_file="$PZ_STATE_DIR/server-manifest"
installed=$(cat "$state_file" 2>/dev/null || true)
server_update=false
if [[ "$installed" =~ ^[0-9]+$ ]]; then
    [[ "$installed" == "$online" ]] || server_update=true
else
    printf '%s\n' "$online" > "$state_file"
    chown steam:steam "$state_file" 2>/dev/null || true
    installed=$online
fi

service_active=false
systemctl is-active --quiet "$PZ_SERVICE" && service_active=true
mod_update=false
mod_check=skipped
mod_result=""

if [[ "$service_active" == true && -e "$PZ_CONTROL_FIFO" ]]; then
    mod_check=unknown
    start_ts=$(date --iso-8601=seconds)
    if pz_send_console checkModsNeedUpdate; then
        for _ in {1..10}; do
            sleep 1
            lines=$(journalctl -u "$PZ_SERVICE" --since "$start_ts" --no-pager -o cat 2>/dev/null | grep -F 'CheckModsNeedUpdate:' || true)
            if grep -Fq 'CheckModsNeedUpdate: Mods need update' <<< "$lines"; then
                mod_update=true
                mod_check=needs-update
                mod_result="Mods need update"
                break
            fi
            result=$(grep -F 'CheckModsNeedUpdate:' <<< "$lines" | grep -vF 'Checking...' | tail -n1 || true)
            if [[ -n "$result" ]]; then
                mod_check=up-to-date
                mod_result=${result#*CheckModsNeedUpdate: }
                break
            fi
        done
    fi
fi

reasons=()
[[ "$server_update" == true ]] && reasons+=("Serverupdate")
[[ "$mod_update" == true ]] && reasons+=("Modupdate")

if (( ${#reasons[@]} == 0 )); then
    message="ProjectZomboid-Server ist up2date. Version: $online."
    details=$(jq -cn --arg online "$online" --arg mod_check "$mod_check" --arg mod_result "$mod_result" '{available_version:$online,installed_version:$online,mod_check:$mod_check,mod_result:(if $mod_result=="" then null else $mod_result end)}')
    echo "$message"
    mqtt_publish_both "gameserverupdate" "success" "success" "project-zomboid" "$message" 0 "" "$details"
    if [[ "$mod_check" == unknown ]]; then
        mqtt_publish_event warning project-zomboid "Mod-Updateprüfung lieferte keine eindeutige Antwort" 0 "$details"
    fi
    exit 0
fi

reason_text=$(IFS=', '; echo "${reasons[*]}")
message="ProjectZomboid-Update erkannt ($reason_text). Onlineversion: $online. Installierte Version: $installed."
details=$(jq -cn --arg online "$online" --arg installed "$installed" --arg reasons "$reason_text" --arg mod_check "$mod_check" '{available_version:$online,installed_version:$installed,reasons:$reasons,mod_check:$mod_check}')
echo "$message"
mqtt_publish_both "gameserverupdate" "success" "warning" "project-zomboid" "$message" 0 "" "$details"

if [[ "$service_active" != true ]]; then
    warning="Update erkannt, aber $PZ_SERVICE ist gestoppt; kein automatischer Start/Restart."
    echo "$warning" >&2
    mqtt_publish_event warning project-zomboid "$warning" 0 "$details"
    exit 0
fi

if [[ "$CHECK_ONLY" == true ]]; then
    echo "CHECK-ONLY: Update erkannt; kein Countdown/Restart."
    mqtt_publish_event warning project-zomboid "Check-only: $reason_text erkannt; kein Restart" 0 "$details"
    exit 0
fi

pz_send_console 'servermsg "Attention: Serverupdate incoming"' || true
pz_countdown_5m
systemctl restart "$PZ_SERVICE"
mqtt_publish_event success project-zomboid "Kontrollierter Restart wegen $reason_text ausgelöst" 0 "$details"
