#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "server-tools permissions: root required" >&2; exit 1; }

repo=/opt/server-tools
account=server-tools

id "$account" >/dev/null 2>&1 || { echo "server-tools permissions: account '$account' missing" >&2; exit 1; }

set_root_file() {
    local mode=$1 path=$2
    [[ -e "$path" && ! -L "$path" ]] || return 0
    chown root:root "$path"
    chmod "$mode" "$path"
}

set_group_file() {
    local mode=$1 group=$2 path=$3
    [[ -e "$path" && ! -L "$path" ]] || return 0
    getent group "$group" >/dev/null 2>&1 || return 0
    chown root:"$group" "$path"
    chmod "$mode" "$path"
}

# Git metadata is needed only by the privileged launcher.
if [[ -d "$repo/.git" && ! -L "$repo/.git" ]]; then
    chown root:root "$repo/.git"
    chmod 700 "$repo/.git"
fi

# Baseline for shell code: root owns repository code, while the dedicated
# server-tools account may read/execute non-privileged framework scripts.
# Privileged and service-specific paths are tightened/overridden below.
while IFS= read -r -d '' path; do
    chown root:"$account" "$path"
    chmod 750 "$path"
done < <(find "$repo" -path "$repo/.git" -prune -o -type f -name '*.sh' -print0)

# Root-only framework entry points and privileged jobs/tools.
root_exec=(
    "$repo/bootstrap/apply-permissions.sh"
    "$repo/bootstrap/dispatch.sh"
    "$repo/bootstrap/manage-server-tools.sh"
    "$repo/bootstrap/server-tools-launcher.sh"
    "$repo/bootstrap/setup-mqtt-env.sh"
    "$repo/scheduler/run-job.sh"
    "$repo/scheduler/run-scheduler.sh"
    "$repo/jobs/debian-update/run.sh"
    "$repo/jobs/mount-check/run.sh"
    "$repo/projects/project-zomboid/update/check-update.sh"
    "$repo/projects/project-zomboid/tools/fix-permissions.sh"
    "$repo/projects/project-zomboid/tools/install-systemd.sh"
    "$repo/projects/project-zomboid/tools/shutdown.sh"
    "$repo/tools/pi-usb-disk-check/pi-usb-disk-check.sh"
)
for path in "${root_exec[@]}"; do set_root_file 700 "$path"; done

# Root-only data/configuration consumed by privileged framework code.
root_read=(
    "$repo/config/base-packages.conf"
    "$repo/config/jobs.conf"
    "$repo/config/sync.conf"
    "$repo/projects/project-zomboid/systemd/zomboid.service"
    "$repo/projects/project-zomboid/systemd/zomboid.socket"
)
for path in "${root_read[@]}"; do set_root_file 600 "$path"; done

# Shared framework libraries/helpers: root owns them; server-tools may read/execute.
set_group_file 640 "$account" "$repo/lib/mqtt.sh"
set_group_file 750 "$account" "$repo/lib/send2mqtt-legacy.sh"
set_group_file 750 "$account" "$repo/services/pihole-dns2mqtt/pihole-dns2mqtt.sh"

# Project Zomboid service files are executed/read by the dedicated steam account.
# They are not assigned to server-tools because the game service deliberately
# runs as steam.
if id steam >/dev/null 2>&1 && getent group steam >/dev/null 2>&1; then
    set_group_file 640 steam "$repo/projects/project-zomboid/config.conf"
    set_group_file 640 steam "$repo/projects/project-zomboid/lib/common.sh"
    set_group_file 750 steam "$repo/projects/project-zomboid/service/start-server.sh"
    set_group_file 640 steam "$repo/projects/project-zomboid/service/steam-update.txt"
else
    set_root_file 600 "$repo/projects/project-zomboid/config.conf"
    set_root_file 600 "$repo/projects/project-zomboid/lib/common.sh"
    set_root_file 700 "$repo/projects/project-zomboid/service/start-server.sh"
    set_root_file 600 "$repo/projects/project-zomboid/service/steam-update.txt"
fi

# Installed launcher and local root-only scheduler/configuration.
set_root_file 700 /usr/local/sbin/server-tools-launcher
set_root_file 600 /etc/cron.d/server-tools
set_root_file 600 /etc/server-tools/config/github.conf
set_root_file 600 /etc/server-tools/config/sync.conf
set_root_file 600 /etc/server-tools/scheduler/scheduler-groups.conf
set_root_file 600 /etc/server-tools/scheduler/jobs.local.conf
set_root_file 600 /etc/server-tools/credentials/github.key
set_root_file 600 /etc/server-tools/credentials/github_known_hosts

# MQTT credentials are intentionally readable by the server-tools service
# account so non-privileged framework components can publish events.
if [[ -f /etc/server-tools/credentials/mqtt.env && ! -L /etc/server-tools/credentials/mqtt.env ]]; then
    chown root:"$account" /etc/server-tools/credentials/mqtt.env
    chmod 640 /etc/server-tools/credentials/mqtt.env
fi

# Privileged framework configuration/state/logs are root-only.
for dir in     /etc/server-tools/config     /etc/server-tools/scheduler     /var/lib/server-tools/bootstrap     /var/lib/server-tools/scheduler     /var/log/server-tools/jobs     /run/server-tools/locks; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    chown root:root "$dir"
    chmod 700 "$dir"
done

set_root_file 600 /var/log/server-tools/launcher.log


verify_file_mode() {
    local expected_owner=$1 expected_group=$2 expected_mode=$3 path=$4 actual
    [[ -e "$path" && ! -L "$path" ]] || return 0
    actual=$(stat -c '%U:%G:%a' "$path")
    if [[ "$actual" != "$expected_owner:$expected_group:$expected_mode" ]]; then
        echo "server-tools permissions: unexpected permissions on $path: $actual (expected $expected_owner:$expected_group:$expected_mode)" >&2
        return 1
    fi
}

verify_dir_mode() {
    verify_file_mode "$@"
}

# Fail closed if a privileged path was not tightened as intended.
for path in "${root_exec[@]}"; do verify_file_mode root root 700 "$path"; done
for path in "${root_read[@]}"; do verify_file_mode root root 600 "$path"; done
verify_file_mode root "$account" 640 "$repo/lib/mqtt.sh"
verify_file_mode root "$account" 750 "$repo/lib/send2mqtt-legacy.sh"
verify_file_mode root "$account" 750 "$repo/services/pihole-dns2mqtt/pihole-dns2mqtt.sh"

if id steam >/dev/null 2>&1 && getent group steam >/dev/null 2>&1; then
    verify_file_mode root steam 640 "$repo/projects/project-zomboid/config.conf"
    verify_file_mode root steam 640 "$repo/projects/project-zomboid/lib/common.sh"
    verify_file_mode root steam 750 "$repo/projects/project-zomboid/service/start-server.sh"
    verify_file_mode root steam 640 "$repo/projects/project-zomboid/service/steam-update.txt"
fi

verify_file_mode root root 700 /usr/local/sbin/server-tools-launcher
verify_file_mode root root 600 /etc/cron.d/server-tools
verify_file_mode root root 600 /etc/server-tools/config/github.conf
verify_file_mode root root 600 /etc/server-tools/config/sync.conf
verify_file_mode root root 600 /etc/server-tools/scheduler/scheduler-groups.conf
verify_file_mode root root 600 /etc/server-tools/scheduler/jobs.local.conf
verify_file_mode root root 600 /etc/server-tools/credentials/github.key
verify_file_mode root root 600 /etc/server-tools/credentials/github_known_hosts
verify_file_mode root "$account" 640 /etc/server-tools/credentials/mqtt.env

for dir in     /etc/server-tools/config     /etc/server-tools/scheduler     /var/lib/server-tools/bootstrap     /var/lib/server-tools/scheduler     /var/log/server-tools/jobs     /run/server-tools/locks; do
    verify_dir_mode root root 700 "$dir"
done


verify_dir_mode root root 700 "$repo/.git"
