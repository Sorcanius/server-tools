#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games

source /opt/server-tools/projects/project-zomboid/lib/common.sh

command -v steamcmd >/dev/null 2>&1 || { echo "project-zomboid: steamcmd not found" >&2; exit 1; }
[[ -x "$PZ_INSTALL_DIR/start-server.sh" ]] || { echo "project-zomboid: start-server.sh missing in $PZ_INSTALL_DIR" >&2; exit 1; }

steamcmd +runscript "$PZ_STEAM_RUNSCRIPT"

if [[ -d "$PZ_STATE_DIR" && -w "$PZ_STATE_DIR" ]]; then
    if manifest=$(pz_online_manifest 2>/dev/null) && [[ "$manifest" =~ ^[0-9]+$ ]]; then
        tmp=$(mktemp "$PZ_STATE_DIR/.server-manifest.XXXXXX")
        printf '%s\n' "$manifest" > "$tmp"
        mv -f "$tmp" "$PZ_STATE_DIR/server-manifest"
    else
        echo "project-zomboid: warning: could not refresh online manifest state" >&2
    fi
else
    echo "project-zomboid: warning: state directory not writable: $PZ_STATE_DIR" >&2
fi

cd "$PZ_INSTALL_DIR"
exec "$PZ_INSTALL_DIR/start-server.sh" -servername "$PZ_SERVER_NAME" < "$PZ_CONTROL_FIFO"
