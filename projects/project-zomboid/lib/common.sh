#!/usr/bin/env bash
set -Eeuo pipefail

PZ_CONFIG=/opt/server-tools/projects/project-zomboid/config.conf
[[ -r "$PZ_CONFIG" ]] || { echo "project-zomboid: missing config $PZ_CONFIG" >&2; return 1 2>/dev/null || exit 1; }
source "$PZ_CONFIG"

pz_send_console() {
    local command=${1:?command required}
    [[ -p "$PZ_CONTROL_FIFO" && ! -L "$PZ_CONTROL_FIFO" ]] || { echo "project-zomboid: control FIFO missing: $PZ_CONTROL_FIFO" >&2; return 1; }
    if (( EUID == 0 )); then
        /usr/sbin/runuser -u steam -- /usr/bin/timeout 10 /usr/bin/bash -c '[[ -p "$1" && ! -L "$1" ]] || exit 1; printf "%s\\n" "$2" > "$1"' _ "$PZ_CONTROL_FIFO" "$command"
    else
        printf '%s\n' "$command" > "$PZ_CONTROL_FIFO"
    fi
}

pz_countdown_5m() {
    pz_send_console 'servermsg "Servershutdown in 5 Minutes"'
    sleep 120
    pz_send_console 'servermsg "Servershutdown in 3 Minutes"'
    sleep 60
    pz_send_console 'servermsg "Servershutdown in 2 Minutes"'
    sleep 60
    pz_send_console 'servermsg "Servershutdown in 1 Minute"'
    sleep 30
    pz_send_console 'servermsg "Servershutdown in 30 Seconds"'
    sleep 30
}

pz_online_manifest() {
    curl -fsS --max-time 30 "$PZ_MANIFEST_API_BASE/$PZ_APP_ID" |
        jq -er --arg app "$PZ_APP_ID" --arg depot "$PZ_DEPOT_ID" '.data[$app].depots[$depot].manifests.public.download'
}
