#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/pihole-mqtt.env"

if (( EUID != 0 )); then
    echo "ERROR: Run this script as root, e.g. sudo $0" >&2
    exit 1
fi

if [[ -e "$CONFIG_FILE" ]]; then
    echo "ABORT: $CONFIG_FILE already exists. Nothing was changed." >&2
    exit 1
fi

umask 077
cat > "$CONFIG_FILE" <<'ENVEOF'
# MQTT connection
MQTT_HOST="EDIT_ME"
MQTT_PORT="1883"
MQTT_USER="EDIT_ME"
MQTT_PASSWORD="EDIT_ME"
MQTT_QOS="0"

# MQTT topic tree
MQTT_BASE_TOPIC="home/device/pihole"

# DNS event streams
PUBLISH_REQUESTS_TO_UNBOUND="true"
PUBLISH_REQUESTS_TO_PIHOLE="false"

# Pi-hole / Unbound
PIHOLE_LOG="/var/log/pihole/pihole.log"
UNBOUND_TARGET="127.0.0.1#5335"

# Resolve a readable client name when possible; IP remains the fallback.
RESOLVE_CLIENT_NAMES="true"
ENVEOF

chown root:root "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo "MQTT configuration created at: $CONFIG_FILE"
echo "IMPORTANT: Edit this file now and replace the EDIT_ME values before starting pihole-dns2mqtt.sh."
