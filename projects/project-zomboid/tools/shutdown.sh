#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo "project-zomboid shutdown: root required" >&2; exit 1; }
source /opt/server-tools/projects/project-zomboid/lib/common.sh

if ! systemctl is-active --quiet "$PZ_SERVICE"; then
    echo "$PZ_SERVICE ist nicht aktiv."
    exit 0
fi

pz_countdown_5m
systemctl stop "$PZ_SERVICE"
