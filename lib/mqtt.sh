#!/usr/bin/env bash
if (( EUID == 0 )); then
    SERVER_TOOLS_MQTT_CONFIG=/etc/server-tools/credentials/mqtt.env
else
    SERVER_TOOLS_MQTT_CONFIG="${SERVER_TOOLS_MQTT_CONFIG:-/etc/server-tools/credentials/mqtt.env}"
fi

_mqtt_loaded=0
mqtt_load_config() {
    (( _mqtt_loaded == 1 )) && return 0
    if [[ -r "$SERVER_TOOLS_MQTT_CONFIG" ]]; then
        if (( EUID == 0 )); then
            local p="$SERVER_TOOLS_MQTT_CONFIG" m
            while [[ "$p" != / ]]; do
                [[ ! -L "$p" && $(stat -c %u -- "$p") == 0 ]] || return 1
                m=$(stat -c %a -- "$p") || return 1
                (( (8#$m & 0022) == 0 )) || return 1
                p=$(dirname -- "$p")
            done
            [[ -f "$SERVER_TOOLS_MQTT_CONFIG" ]] || return 1
        fi
        # shellcheck disable=SC1090
        source "$SERVER_TOOLS_MQTT_CONFIG"
    fi
    : "${MQTT_LEGACY_HOST:=}"
    : "${MQTT_LEGACY_PORT:=1883}"
    : "${MQTT_LEGACY_USER:=}"
    : "${MQTT_LEGACY_PASSWORD:=}"
    : "${MQTT_LEGACY_ENABLED:=true}"
    : "${MQTT_HOST:=}"
    : "${MQTT_PORT:=1883}"
    : "${MQTT_USER:=}"
    : "${MQTT_PASSWORD:=}"
    : "${MQTT_NEW_ENABLED:=true}"
    _mqtt_loaded=1
}

_mqtt_bool_true() {
    case "${1,,}" in 1|true|yes|on|enabled) return 0 ;; *) return 1 ;; esac
}

_mqtt_configured_host() {
    [[ -n "$1" && "$1" != EDIT_ME ]]
}

_mqtt_pub() {
    local host=$1 port=$2 user=$3 password=$4 qos=$5 topic=$6 payload=$7
    local args=(-h "$host" -p "$port" -q "$qos" -t "$topic" -m "$payload")
    [[ -z "$user" || "$user" == EDIT_ME ]] || args+=(-u "$user")
    [[ -z "$password" || "$password" == EDIT_ME ]] || args+=(-P "$password")
    if ! mosquitto_pub "${args[@]}"; then
        echo "server-tools mqtt: publish failed topic=$topic" >&2
        return 1
    fi
}

mqtt_publish_legacy_json() {
    mqtt_load_config || return 1
    _mqtt_bool_true "$MQTT_LEGACY_ENABLED" || return 0
    _mqtt_configured_host "$MQTT_LEGACY_HOST" || return 0
    local payload=${1:?payload required}
    local fqdn topic
    fqdn=$(hostname -f 2>/dev/null || hostname)
    topic="home/device/computer/$fqdn"
    _mqtt_pub "$MQTT_LEGACY_HOST" "$MQTT_LEGACY_PORT" "$MQTT_LEGACY_USER" "$MQTT_LEGACY_PASSWORD" 0 "$topic" "$payload" || true
}

mqtt_publish_legacy() {
    local process=${1:?process required}
    local status=${2:?status required}
    local message=${3:-}
    local error=${4:-}
    local payload
    if [[ -n "$error" ]]; then
        payload=$(jq -cn             --arg devicename "$(hostname)"             --arg process "$process"             --arg status "$status"             --arg message "$message"             --arg error "$error"             '{devicename:$devicename,process:$process,status:$status,message:$message,error:$error,errors:$error}')
    else
        payload=$(jq -cn             --arg devicename "$(hostname)"             --arg process "$process"             --arg status "$status"             --arg message "$message"             '{devicename:$devicename,process:$process,status:$status,message:$message}')
    fi
    mqtt_publish_legacy_json "$payload"
}

_mqtt_primary_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

_mqtt_primary_mac() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n "$iface" && -r "/sys/class/net/$iface/address" ]] && cat "/sys/class/net/$iface/address" || true
}

mqtt_publish_event() {
    mqtt_load_config || return 1
    _mqtt_bool_true "$MQTT_NEW_ENABLED" || return 0
    _mqtt_configured_host "$MQTT_HOST" || return 0

    local category=${1:?category required}
    local service=${2:?service required}
    local message=${3:-}
    local exit_code=${4:-0}
    local details_json=${5:-'{}'}
    local hostname_short fqdn topic event_id ts_utc ts_local tz ip mac os kernel arch payload

    case "$category" in critical|error|warning|success|heartbeat) ;; *) category=warning ;; esac
    jq -e . >/dev/null 2>&1 <<< "$details_json" || details_json='{}'

    hostname_short=$(hostname)
    fqdn=$(hostname -f 2>/dev/null || hostname)
    ts_utc=$(date -u --iso-8601=seconds)
    ts_local=$(date --iso-8601=seconds)
    tz=$(date +%:z)
    ip=$(_mqtt_primary_ip)
    mac=$(_mqtt_primary_mac)
    os=$(awk -F= '$1=="PRETTY_NAME" {gsub(/^"|"$/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true)
    kernel=$(uname -r)
    arch=$(uname -m)
    event_id="${hostname_short}-$(date +%s%N)-$$-$RANDOM"
    topic="/home/device/server-tools/$category/$fqdn"

    payload=$(jq -cn         --argjson details "$details_json"         --arg event_id "$event_id"         --arg hostname "$hostname_short"         --arg fqdn "$fqdn"         --arg user "$(id -un)"         --arg timestamp_utc "$ts_utc"         --arg timestamp_local "$ts_local"         --arg timezone_offset "$tz"         --arg ip "$ip"         --arg mac "$mac"         --arg os "$os"         --arg kernel "$kernel"         --arg arch "$arch"         --arg service "$service"         --arg category "$category"         --arg message "$message"         --argjson exit_code "$exit_code"         '{schema_version:1,event_id:$event_id,system:{hostname:$hostname,fqdn:$fqdn,user:$user,timestamp_utc:$timestamp_utc,timestamp_local:$timestamp_local,timezone_offset:$timezone_offset,ip:(if $ip=="" then null else $ip end),mac:(if $mac=="" then null else $mac end),os:(if $os=="" then null else $os end),kernel:$kernel,arch:$arch},service:{name:$service},details:($details + {category:$category,message:$message,exit_code:$exit_code})}')

    _mqtt_pub "$MQTT_HOST" "$MQTT_PORT" "$MQTT_USER" "$MQTT_PASSWORD" 1 "$topic" "$payload" || true
}

mqtt_publish_both() {
    local legacy_process=$1 legacy_status=$2 category=$3 service=$4 message=$5 exit_code=${6:-0} error=${7:-} details=${8:-'{}'}
    mqtt_publish_legacy "$legacy_process" "$legacy_status" "$message" "$error"
    mqtt_publish_event "$category" "$service" "$message" "$exit_code" "$details"
}
