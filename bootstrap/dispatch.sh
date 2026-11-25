#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
[[ $EUID == 0 ]] || { echo "Root required" >&2; exit 1; }
missing=()
while IFS= read -r p; do
 [[ $p =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || continue
 [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true) == installed ]] || missing+=("$p")
done < /opt/server-tools/config/base-packages.conf
if (( ${#missing[@]} )); then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; fi
if [[ ! -e /etc/server-tools/config/sync.conf ]]; then
 (umask 022; set -o noclobber; sed '/^[a-z]/s/^/# /' /opt/server-tools/config/sync.conf > /etc/server-tools/config/sync.conf)
fi
if [[ ! -e /etc/server-tools/credentials/mqtt.env ]]; then
 /opt/server-tools/bootstrap/setup-mqtt-env.sh
fi
if [[ ! -e /etc/server-tools/scheduler/scheduler-groups.conf ]]; then
 (set -o noclobber; printf '%s\n' '# No groups available yet. New groups will default to disabled.' > /etc/server-tools/scheduler/scheduler-groups.conf)
fi
