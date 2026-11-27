#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset BASH_ENV ENV CDPATH
cd /

[[ $EUID == 0 ]] || { echo "server-tools job-runner: root required" >&2; exit 1; }

job_id="${1:?job id required}"
script="${2:?script required}"
run_user="${3:-server-tools}"
timeout_seconds="${4:-0}"

[[ "$job_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "invalid job id" >&2; exit 2; }
[[ "$timeout_seconds" =~ ^(0|[1-9][0-9]{0,6})$ ]] || { echo "invalid timeout" >&2; exit 2; }
[[ "$script" == /opt/server-tools/* && -f "$script" && ! -L "$script" && $(realpath -e -- "$script") == "$script" ]] || { echo "job script unavailable: $script" >&2; exit 2; }
id "$run_user" >/dev/null 2>&1 || { echo "job user missing: $run_user" >&2; exit 2; }

runtime=/run/server-tools/locks
logdir=/var/log/server-tools/jobs
install -d -o root -g root -m 700 "$runtime" "$logdir"
logfile="$logdir/$job_id.log"
lockfile="$runtime/job-$job_id.lock"

exec 8<>/run/server-tools/locks/repository.lock
flock -s 8
p="$script"
while [[ "$p" != / ]]; do
    [[ ! -L "$p" && $(stat -c %u -- "$p") == 0 ]] || exit 2
    m=$(stat -c %a -- "$p")
    (( (8#$m & 0022) == 0 )) || exit 2
    p=$(dirname -- "$p")
done
exec 9>"$lockfile"
if ! flock -n 9; then
    printf '%s job=%s status=skipped reason=already-running\n' "$(date --iso-8601=seconds)" "$job_id" >> "$logfile"
    exit 0
fi

start_epoch=$(date +%s)
printf '%s job=%s status=started user=%s script=%s\n' "$(date --iso-8601=seconds)" "$job_id" "$run_user" "$script" >> "$logfile"

run_command() {
    if [[ "$run_user" == root ]]; then
        /usr/bin/bash "$script"
    else
        /usr/sbin/runuser -u "$run_user" -- /usr/bin/bash "$script"
    fi
}

set +e
if (( timeout_seconds > 0 )); then
    timeout --signal=TERM --kill-after=60s "$timeout_seconds" bash -c '
        script=$1
        run_user=$2
        if [[ "$run_user" == root ]]; then
            exec /usr/bin/bash "$script"
        else
            exec /usr/sbin/runuser -u "$run_user" -- /usr/bin/bash "$script"
        fi
    ' _ "$script" "$run_user" >> "$logfile" 2>&1
    rc=$?
else
    run_command >> "$logfile" 2>&1
    rc=$?
fi
set -e

end_epoch=$(date +%s)
duration=$((end_epoch-start_epoch))
printf '%s job=%s status=finished exit_code=%s duration_seconds=%s\n' "$(date --iso-8601=seconds)" "$job_id" "$rc" "$duration" >> "$logfile"
exit "$rc"
