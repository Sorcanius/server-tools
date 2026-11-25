#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo "Root required" >&2; exit 1; }
file=/etc/server-tools/credentials/mqtt.env
install -d -o root -g server-tools -m 750 /etc/server-tools/credentials
if [[ -e "$file" || -L "$file" ]]; then echo "Existing credentials preserved"; exit 0; fi
umask 077
(set -o noclobber; cat > "$file" <<'EOF'
# MQTT broker hostname or IP (required).
# MQTT_HOST=
# MQTT broker port (default: 1883).
# MQTT_PORT=1883
# MQTT username (optional for anonymous access).
# MQTT_USER=
# MQTT password (optional for anonymous access).
# MQTT_PASSWORD=
EOF
)
chown root:server-tools "$file"
chmod 640 "$file"
