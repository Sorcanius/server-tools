#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
[[ $EUID == 0 ]] || { echo "Root required" >&2; exit 1; }

repo=/opt/server-tools
missing=()
while IFS= read -r p; do
    [[ $p =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || continue
    [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true) == installed ]] || missing+=("$p")
done < "$repo/config/base-packages.conf"
if (( ${#missing[@]} )); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi

install -d -o root -g root -m 700     /etc/server-tools/config     /etc/server-tools/scheduler     /var/lib/server-tools/scheduler     /var/lib/server-tools/scheduler/jobs     /var/log/server-tools/jobs     /run/server-tools/locks
install -d -o root -g root -m 755 /var/lib/server-tools/projects

if [[ ! -e /etc/server-tools/config/sync.conf ]]; then
    (umask 022; set -o noclobber; sed '/^[a-z]/s/^/# /' "$repo/config/sync.conf" > /etc/server-tools/config/sync.conf)
fi

"$repo/bootstrap/setup-mqtt-env.sh" >/dev/null

groups=/etc/server-tools/scheduler/scheduler-groups.conf
if [[ ! -e "$groups" ]]; then
    install -o root -g root -m 600 /dev/null "$groups"
    printf '%s\n' '# Local server-tools job-group opt-in. New groups default to disabled.' > "$groups"
fi

while IFS= read -r group; do
    [[ -n "$group" ]] || continue
    if ! grep -Eq "^[[:space:]]*${group}=" "$groups"; then
        printf '%s=disabled\n' "$group" >> "$groups"
    fi
done < <(awk -F'|' '$0 !~ /^#/ && NF>=2 {print $2}' "$repo/config/jobs.conf" | sort -u)

local_jobs=/etc/server-tools/scheduler/jobs.local.conf
if [[ ! -e "$local_jobs" ]]; then
    (umask 077
        {
            echo '# Optional local job overrides. See /opt/server-tools/config/jobs.local.conf.example'
            echo '# Leave empty to use central defaults.'
        } > "$local_jobs"
    )
fi

"$repo/bootstrap/apply-permissions.sh"
"$repo/scheduler/run-scheduler.sh"
