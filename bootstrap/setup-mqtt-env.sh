#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo "Root required" >&2; exit 1; }

file=/etc/server-tools/credentials/mqtt.env
template=/opt/server-tools/config/mqtt.env.example
install -d -o root -g server-tools -m 750 /etc/server-tools/credentials

if [[ ! -e "$file" ]]; then
    [[ -r "$template" ]] || { echo "Missing template: $template" >&2; exit 1; }
    umask 077
    cp "$template" "$file"
    chown root:server-tools "$file"
    chmod 640 "$file"
    echo "MQTT credential template created: $file"
    echo "IMPORTANT: edit both credential sets before enabling MQTT publishing."
    exit 0
fi

[[ -f "$file" && ! -L "$file" ]] || { echo "Unsafe MQTT credential path: $file" >&2; exit 1; }

append_if_missing() {
    local key=$1 value=$2 comment=$3
    if ! grep -Eq "^[[:space:]]*${key}=" "$file"; then
        {
            echo
            echo "# $comment"
            printf '%s=%s\n' "$key" "$value"
        } >> "$file"
    fi
}

append_if_missing MQTT_LEGACY_HOST '""' 'Legacy MQTT broker hostname/IP (migration path).'
append_if_missing MQTT_LEGACY_PORT '"1883"' 'Legacy MQTT broker port.'
append_if_missing MQTT_LEGACY_USER '""' 'Legacy MQTT username.'
append_if_missing MQTT_LEGACY_PASSWORD '""' 'Legacy MQTT password.'
append_if_missing MQTT_LEGACY_ENABLED '"true"' 'Publish legacy messages during migration.'
append_if_missing MQTT_HOST '""' 'New server-tools MQTT broker hostname/IP.'
append_if_missing MQTT_PORT '"1883"' 'New server-tools MQTT broker port.'
append_if_missing MQTT_USER '""' 'New server-tools MQTT username.'
append_if_missing MQTT_PASSWORD '""' 'New server-tools MQTT password.'
append_if_missing MQTT_NEW_ENABLED '"true"' 'Publish new server-tools events.'

chown root:server-tools "$file"
chmod 640 "$file"
echo "Existing MQTT credentials preserved and missing template keys added: $file"
