#!/usr/bin/env bash
set -Eeuo pipefail

# Publish Pi-hole DNS activity to MQTT.
#
# Required Pi-hole settings:
#   sudo pihole-FTL --config dns.queryLogging true
#   sudo pihole-FTL --config misc.extraLogging true
#   sudo systemctl restart pihole-FTL
#
# The extraLogging setting is important: it adds a query serial number and
# the original requester's IP address to each dnsmasq log line. This lets us
# attribute an upstream forward to the client that caused it.

CONFIG_FILE="${MQTT_CONFIG:-/etc/mqtt.env}"

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "ERROR: MQTT config not readable: $CONFIG_FILE" >&2
    echo "Run setup-mqtt-env.sh first and then edit the file." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${MQTT_HOST:?MQTT_HOST is not set in $CONFIG_FILE}"
: "${MQTT_PORT:=1883}"
: "${MQTT_USER:=}"
: "${MQTT_PASSWORD:=}"

# Pi-hole-specific settings belong in this script, not in the generic MQTT
# credential file.
readonly MQTT_BASE_TOPIC="home/device/pihole"
readonly MQTT_QOS="0"
readonly PIHOLE_LOG="/var/log/pihole/pihole.log"
readonly UNBOUND_TARGET="127.0.0.1#5335"
readonly PUBLISH_REQUESTS_TO_UNBOUND="true"
readonly PUBLISH_REQUESTS_TO_PIHOLE="false"
readonly RESOLVE_CLIENT_NAMES="true"

if [[ "$MQTT_HOST" == "EDIT_ME" || "$MQTT_USER" == "EDIT_ME" || "$MQTT_PASSWORD" == "EDIT_ME" ]]; then
    echo "ERROR: $CONFIG_FILE still contains EDIT_ME placeholders." >&2
    exit 1
fi

if [[ ! "$MQTT_PORT" =~ ^[0-9]+$ ]] || (( MQTT_PORT < 1 || MQTT_PORT > 65535 )); then
    echo "ERROR: Invalid MQTT_PORT: $MQTT_PORT" >&2
    exit 1
fi

if [[ ! "$MQTT_QOS" =~ ^[012]$ ]]; then
    echo "ERROR: MQTT_QOS must be 0, 1 or 2." >&2
    exit 1
fi

case "$PUBLISH_REQUESTS_TO_UNBOUND" in true|false) ;; *) echo "ERROR: PUBLISH_REQUESTS_TO_UNBOUND must be true or false." >&2; exit 1 ;; esac
case "$PUBLISH_REQUESTS_TO_PIHOLE" in true|false) ;; *) echo "ERROR: PUBLISH_REQUESTS_TO_PIHOLE must be true or false." >&2; exit 1 ;; esac
case "$RESOLVE_CLIENT_NAMES" in true|false) ;; *) echo "ERROR: RESOLVE_CLIENT_NAMES must be true or false." >&2; exit 1 ;; esac

if [[ "$PUBLISH_REQUESTS_TO_UNBOUND" != "true" && "$PUBLISH_REQUESTS_TO_PIHOLE" != "true" ]]; then
    echo "ERROR: Both publish streams are disabled." >&2
    exit 1
fi

for cmd in tail mosquitto_pub jq ip awk sed date; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    }
done

if [[ "$RESOLVE_CLIENT_NAMES" == "true" ]]; then
    command -v getent >/dev/null 2>&1 || {
        echo "ERROR: RESOLVE_CLIENT_NAMES=true but getent is not installed." >&2
        exit 1
    }
fi

if [[ ! -r "$PIHOLE_LOG" ]]; then
    echo "ERROR: Pi-hole log not readable: $PIHOLE_LOG" >&2
    exit 1
fi

# Refuse obviously unsafe credential-file permissions. 600 is what the setup
# helper creates; 400 is also acceptable.
if command -v stat >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || true)"
    case "$mode" in
        400|600) ;;
        *)
            echo "WARNING: $CONFIG_FILE has mode ${mode:-unknown}; recommended: 600 root:root." >&2
            ;;
    esac
fi

MQTT_ARGS=(-h "$MQTT_HOST" -p "$MQTT_PORT" -q "$MQTT_QOS")
if [[ -n "$MQTT_USER" ]]; then
    MQTT_ARGS+=(-u "$MQTT_USER")
fi
if [[ -n "$MQTT_PASSWORD" ]]; then
    MQTT_ARGS+=(-P "$MQTT_PASSWORD")
fi

RUNTIME_BASE="/run"
[[ -d "$RUNTIME_BASE" && -w "$RUNTIME_BASE" ]] || RUNTIME_BASE="/tmp"
RUNTIME_DIR="$(mktemp -d "$RUNTIME_BASE/pihole-dns2mqtt.XXXXXX")"
chmod 700 "$RUNTIME_DIR"

declare -A PUB_PID=()
declare -A PUB_FD=()
declare -A PUB_FIFO=()
TAIL_PID=""
TAIL_FD=""

declare -A QUERY_TYPE=()
declare -A QUERY_DOMAIN=()
declare -A QUERY_TS=()
declare -A CLIENT_NAME_CACHE=()
declare -A CLIENT_MAC_CACHE=()

cleanup() {
    local key fd pid

    if [[ -n "${TAIL_FD:-}" ]]; then
        eval "exec ${TAIL_FD}<&-" 2>/dev/null || true
    fi
    if [[ -n "${TAIL_PID:-}" ]]; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
    fi

    for key in "${!PUB_FD[@]}"; do
        fd="${PUB_FD[$key]}"
        eval "exec ${fd}>&-" 2>/dev/null || true
    done
    for key in "${!PUB_PID[@]}"; do
        pid="${PUB_PID[$key]}"
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$RUNTIME_DIR"
}
trap cleanup EXIT INT TERM HUP
trap 'echo "ERROR: Broken MQTT publisher pipe." >&2; exit 1' PIPE

start_publisher() {
    local key="$1"
    local topic="$2"
    local fifo="$RUNTIME_DIR/${key}.fifo"
    local fd pid

    mkfifo -m 600 "$fifo"
    mosquitto_pub "${MQTT_ARGS[@]}" -t "$topic" -l <"$fifo" &
    pid=$!
    exec {fd}>"$fifo"

    # Give mosquitto_pub a brief chance to fail fast on bad credentials/broker.
    sleep 0.2
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: MQTT publisher for $topic exited during startup." >&2
        exit 1
    fi

    PUB_PID["$key"]="$pid"
    PUB_FD["$key"]="$fd"
    PUB_FIFO["$key"]="$fifo"
}

publish_line() {
    local key="$1"
    local payload="$2"
    local pid="${PUB_PID[$key]}"
    local fd="${PUB_FD[$key]}"

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: MQTT publisher '$key' is no longer running." >&2
        exit 1
    fi

    printf '%s\n' "$payload" >&"$fd"
}

RESOLVED_CLIENT_NAME=""
RESOLVED_CLIENT_MAC=""
BUILT_PAYLOAD=""

resolve_client_name() {
    local client_ip="$1"
    local name=""

    if [[ ${CLIENT_NAME_CACHE[$client_ip]+_} ]]; then
        RESOLVED_CLIENT_NAME="${CLIENT_NAME_CACHE[$client_ip]}"
        return
    fi

    # Prefer /etc/hosts because it cannot create another DNS request.
    name="$(awk -v ip="$client_ip" '$1 == ip {print $2; exit}' /etc/hosts 2>/dev/null || true)"

    # Fall back to NSS. The result is cached so this is normally done only once
    # per client IP. A failed lookup falls back to the IP itself.
    if [[ -z "$name" && "$RESOLVE_CLIENT_NAMES" == "true" ]]; then
        if command -v timeout >/dev/null 2>&1; then
            name="$(timeout 2 getent hosts "$client_ip" 2>/dev/null | awk 'NR==1 {print $2}' || true)"
        else
            name="$(getent hosts "$client_ip" 2>/dev/null | awk 'NR==1 {print $2}' || true)"
        fi
    fi

    name="${name%.}"
    [[ -n "$name" ]] || name="$client_ip"
    CLIENT_NAME_CACHE["$client_ip"]="$name"
    RESOLVED_CLIENT_NAME="$name"
}

resolve_client_mac() {
    local client_ip="$1"
    local mac=""

    if [[ ${CLIENT_MAC_CACHE[$client_ip]+_} ]]; then
        mac="${CLIENT_MAC_CACHE[$client_ip]}"
        [[ "$mac" == "-" ]] && mac=""
        RESOLVED_CLIENT_MAC="$mac"
        return
    fi

    mac="$(ip neigh show to "$client_ip" 2>/dev/null | awk '
        /lladdr/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "lladdr" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' || true)"

    # Cache successful and unsuccessful lookups. A restart refreshes the cache.
    CLIENT_MAC_CACHE["$client_ip"]="${mac:--}"
    RESOLVED_CLIENT_MAC="$mac"
}

build_payload() {
    local serial="$1"
    local client_ip="$2"
    local domain="$3"
    local query_type="$4"
    local client mac client_id timestamp

    resolve_client_name "$client_ip"
    resolve_client_mac "$client_ip"
    client="$RESOLVED_CLIENT_NAME"
    mac="$RESOLVED_CLIENT_MAC"
    client_id="${mac:-$client_ip}"
    timestamp="$(date --iso-8601=seconds)"
    domain="${domain%.}"

    BUILT_PAYLOAD="$(jq -cn \
        --arg timestamp "$timestamp" \
        --arg request_id "$serial" \
        --arg client "$client" \
        --arg client_id "$client_id" \
        --arg client_ip "$client_ip" \
        --arg client_mac "$mac" \
        --arg domain "$domain" \
        --arg query_type "$query_type" \
        '{
            timestamp: $timestamp,
            request_id: $request_id,
            client: $client,
            client_id: $client_id,
            client_ip: $client_ip,
            client_mac: (if $client_mac == "" then null else $client_mac end),
            domain: $domain,
            query_type: (if $query_type == "" then null else $query_type end)
        }')"
}

prune_query_cache() {
    local now="$EPOCHSECONDS"
    local serial
    for serial in "${!QUERY_TS[@]}"; do
        if (( now - QUERY_TS[$serial] > 600 )); then
            unset 'QUERY_TS[$serial]' 'QUERY_TYPE[$serial]' 'QUERY_DOMAIN[$serial]'
        fi
    done
}

if [[ "$PUBLISH_REQUESTS_TO_UNBOUND" == "true" ]]; then
    start_publisher "unbound" "$MQTT_BASE_TOPIC/RequestsToUnbound"
fi
if [[ "$PUBLISH_REQUESTS_TO_PIHOLE" == "true" ]]; then
    start_publisher "pihole" "$MQTT_BASE_TOPIC/RequestsToPihole"
fi

echo "Monitoring $PIHOLE_LOG"
echo "Unbound target: $UNBOUND_TARGET"
[[ "$PUBLISH_REQUESTS_TO_UNBOUND" == "true" ]] && echo "MQTT: $MQTT_BASE_TOPIC/RequestsToUnbound"
[[ "$PUBLISH_REQUESTS_TO_PIHOLE" == "true" ]] && echo "MQTT: $MQTT_BASE_TOPIC/RequestsToPihole"
echo "Waiting for new DNS log entries..."

line_count=0
warned_missing_extra_logging=false

# Feed tail through a private FIFO so the loop stays in the main shell (the
# associative caches remain persistent) and the tail process can be terminated
# cleanly on shutdown. tail -F follows pihole.log across log rotation.
LOG_FIFO="$RUNTIME_DIR/pihole-log.fifo"
mkfifo -m 600 "$LOG_FIFO"
tail -n0 -F "$PIHOLE_LOG" >"$LOG_FIFO" &
TAIL_PID=$!
exec {TAIL_FD}<"$LOG_FIFO"

while IFS= read -r -u "$TAIL_FD" line; do
    ((++line_count))

    # Expected extraLogging query format, accepting both "IP" and "IP/port":
    #   <serial> <requester> query[A] example.org from <requester>
    if [[ "$line" =~ dnsmasq\[[0-9]+\]:[[:space:]]+([0-9]+)[[:space:]]+([^[:space:]/]+)(/[0-9]+)?[[:space:]]+query\[([^]]+)\][[:space:]]+([^[:space:]]+)[[:space:]]+from[[:space:]]+([^[:space:]]+) ]]; then
        serial="${BASH_REMATCH[1]}"
        client_ip="${BASH_REMATCH[2]}"
        query_type="${BASH_REMATCH[4]}"
        domain="${BASH_REMATCH[5]}"

        QUERY_TYPE["$serial"]="$query_type"
        QUERY_DOMAIN["$serial"]="$domain"
        QUERY_TS["$serial"]="$EPOCHSECONDS"

        if [[ "$PUBLISH_REQUESTS_TO_PIHOLE" == "true" ]]; then
            build_payload "$serial" "$client_ip" "$domain" "$query_type"
            publish_line "pihole" "$BUILT_PAYLOAD"
        fi

    # Expected extraLogging forward format:
    #   <serial> <requester> forwarded example.org to 127.0.0.1#5335
    elif [[ "$line" =~ dnsmasq\[[0-9]+\]:[[:space:]]+([0-9]+)[[:space:]]+([^[:space:]/]+)(/[0-9]+)?[[:space:]]+forwarded[[:space:]]+([^[:space:]]+)[[:space:]]+to[[:space:]]+([^[:space:]]+) ]]; then
        serial="${BASH_REMATCH[1]}"
        client_ip="${BASH_REMATCH[2]}"
        domain="${BASH_REMATCH[4]}"
        upstream="${BASH_REMATCH[5]}"

        if [[ "$PUBLISH_REQUESTS_TO_UNBOUND" == "true" && "$upstream" == "$UNBOUND_TARGET" ]]; then
            query_type="${QUERY_TYPE[$serial]:-}"
            # Prefer the domain from the matching query line if available.
            domain="${QUERY_DOMAIN[$serial]:-$domain}"
            build_payload "$serial" "$client_ip" "$domain" "$query_type"
            publish_line "unbound" "$BUILT_PAYLOAD"
        fi

        unset 'QUERY_TS[$serial]' 'QUERY_TYPE[$serial]' 'QUERY_DOMAIN[$serial]'

    # Detect a normal forwarded line without extraLogging. In that case the
    # original client cannot be attributed from the forwarded line alone.
    elif [[ "$warned_missing_extra_logging" == "false" && "$line" == *" forwarded "* && "$line" == *" to $UNBOUND_TARGET"* ]]; then
        warned_missing_extra_logging=true
        echo "WARNING: Forwarded DNS log line found without extraLogging requester metadata." >&2
        echo "Enable it with:" >&2
        echo "  sudo pihole-FTL --config dns.queryLogging true" >&2
        echo "  sudo pihole-FTL --config misc.extraLogging true" >&2
        echo "  sudo systemctl restart pihole-FTL" >&2
    fi

    (( line_count % 1000 == 0 )) && prune_query_cache

done
