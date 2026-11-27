#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/server-tools/lib/mqtt.sh
payload=$(cat)
mqtt_publish_legacy_json "$payload"
