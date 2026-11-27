#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

[[ $EUID == 0 ]] || { echo "debian-update: root required" >&2; exit 1; }
source /opt/server-tools/lib/mqtt.sh

logfile=$(mktemp /tmp/server-tools-debian-update.XXXXXX.log)
errorfile=$(mktemp /tmp/server-tools-debian-update.XXXXXX.err)
trap 'rm -f "$logfile" "$errorfile"' EXIT

fail() {
    local rc=$1 step=$2
    local err
    err=$(tr '\n' ' ' < "$errorfile" | sed -E 's/[[:space:]]+/ /g' | cut -c1-4000)
    [[ -n "$err" ]] || err="Command failed: $step"
    echo "debian-update: $step failed (rc=$rc): $err" >&2
    mqtt_publish_both "debianupdate" "failure" "error" "debian-update"         "Upgrade fehlgeschlagen" "$rc" "$err"         "$(jq -cn --arg step "$step" --arg error "$err" '{step:$step,error:$error}')"
    exit "$rc"
}

run_step() {
    local name=$1; shift
    : > "$errorfile"
    echo "debian-update: $name"
    if "$@" >> "$logfile" 2>> "$errorfile"; then
        return 0
    else
        local rc=$?
        fail "$rc" "$name"
    fi
}

run_step "apt update" apt update
run_step "apt full-upgrade -y" apt full-upgrade -y
run_step "apt upgrade -y" apt upgrade -y
run_step "apt dist-upgrade -y" apt dist-upgrade -y
run_step "apt autoremove -y" apt autoremove -y

message="Upgrade erfolgreich"
echo "debian-update: $message"
mqtt_publish_both "debianupdate" "success" "success" "debian-update" "$message" 0 "" '{"updated":true}'
