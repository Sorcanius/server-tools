#!/usr/bin/env bash
set -Eeuo pipefail

# Create the generic MQTT connection file used by scripts on this host.
# No real credentials are stored in this repository.

CONFIG_FILE="/etc/mqtt.env"

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
# Generic MQTT connection settings for this device.
# Replace every EDIT_ME value before using MQTT scripts.

MQTT_HOST="EDIT_ME"
MQTT_PORT="1883"
MQTT_USER="EDIT_ME"
MQTT_PASSWORD="EDIT_ME"
ENVEOF

chown root:root "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo "MQTT configuration created at: $CONFIG_FILE"
echo "IMPORTANT: Edit $CONFIG_FILE now and replace the EDIT_ME values."
