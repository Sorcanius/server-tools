#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[[ $EUID == 0 ]] || { echo "server-tools scheduler: root required" >&2; exit 1; }

readonly repo=/opt/server-tools
readonly jobs_file="$repo/config/jobs.conf"
readonly groups_file=/etc/server-tools/scheduler/scheduler-groups.conf
readonly overrides_file=/etc/server-tools/scheduler/jobs.local.conf
readonly state_dir=/var/lib/server-tools/scheduler
readonly runtime_dir=/run/server-tools/locks
readonly job_runner="$repo/scheduler/run-job.sh"

[[ -r "$jobs_file" && -x "$job_runner" ]] || exit 0
install -d -o root -g root -m 755 "$state_dir" "$runtime_dir" /var/log/server-tools/jobs

bool_true() {
    case "${1,,}" in 1|true|yes|on|enabled) return 0 ;; *) return 1 ;; esac
}

group_enabled() {
    local group=$1 value
    [[ -r "$groups_file" ]] || return 1
    value=$(awk -F= -v k="$group" '
        $0 !~ /^[[:space:]]*#/ && $1==k {v=$2}
        END {gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v}
    ' "$groups_file")
    bool_true "$value"
}

override_value() {
    local job=$1 field=$2
    [[ -r "$overrides_file" ]] || return 1
    awk -F= -v k="$job.$field" '
        $0 !~ /^[[:space:]]*#/ && index($0,"=")>0 {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key==k) {
                sub(/^[^=]*=/, "")
                v=$0
            }
        }
        END { if (v!="") print v }
    ' "$overrides_file"
}

cron_atom_match() {
    local value=$1 atom=$2 min=$3 max=$4 base step lo hi
    step=1
    if [[ "$atom" == */* ]]; then
        base=${atom%/*}
        step=${atom##*/}
        [[ "$step" =~ ^[1-9][0-9]*$ ]] || return 1
    else
        base=$atom
    fi

    if [[ "$base" == "*" ]]; then
        lo=$min; hi=$max
    elif [[ "$base" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
    elif [[ "$base" =~ ^[0-9]+$ ]]; then
        lo=$base; hi=$base
    else
        return 1
    fi

    (( lo >= min && hi <= max && lo <= hi && value >= lo && value <= hi )) || return 1
    (( (value-lo) % step == 0 ))
}

cron_field_match() {
    local value=$1 spec=$2 min=$3 max=$4 atom
    IFS=',' read -r -a atoms <<< "$spec"
    for atom in "${atoms[@]}"; do
        cron_atom_match "$value" "$atom" "$min" "$max" && return 0
        if (( max == 7 && value == 0 )); then
            cron_atom_match 7 "$atom" "$min" "$max" && return 0
        fi
    done
    return 1
}

cron_matches() {
    local schedule=$1 epoch=$2 minute hour dom month dow dom_ok=1 dow_ok=1
    local f1 f2 f3 f4 f5 extra
    read -r f1 f2 f3 f4 f5 extra <<< "$schedule"
    [[ -n "$f1" && -n "$f2" && -n "$f3" && -n "$f4" && -n "$f5" && -z "${extra:-}" ]] || return 1
    minute=$(date -d "@$epoch" +%M); minute=$((10#$minute))
    hour=$(date -d "@$epoch" +%H); hour=$((10#$hour))
    dom=$(date -d "@$epoch" +%d); dom=$((10#$dom))
    month=$(date -d "@$epoch" +%m); month=$((10#$month))
    dow=$(date -d "@$epoch" +%w); dow=$((10#$dow))
    cron_field_match "$minute" "$f1" 0 59 || return 1
    cron_field_match "$hour" "$f2" 0 23 || return 1
    cron_field_match "$month" "$f4" 1 12 || return 1
    cron_field_match "$dom" "$f3" 1 31 && dom_ok=0 || true
    cron_field_match "$dow" "$f5" 0 7 && dow_ok=0 || true
    if [[ "$f3" == "*" && "$f5" == "*" ]]; then return 0; fi
    if [[ "$f3" == "*" ]]; then (( dow_ok == 0 )); return; fi
    if [[ "$f5" == "*" ]]; then (( dom_ok == 0 )); return; fi
    (( dom_ok == 0 || dow_ok == 0 ))
}

launch_job() {
    local job=$1 script=$2 user=$3 timeout_s=$4 stamp=$5 safe unit
    safe=${job//[^a-zA-Z0-9_.-]/-}
    unit="server-tools-job-${safe}-${stamp}"
    if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemd-run --quiet --collect --unit="$unit"             /usr/bin/bash "$job_runner" "$job" "$script" "$user" "$timeout_s" || return 1
    else
        nohup /usr/bin/bash "$job_runner" "$job" "$script" "$user" "$timeout_s"             >/dev/null 2>&1 </dev/null &
    fi
}

now=$(date +%s)
now_min=$((now - now%60))
last_file="$state_dir/last-dispatch"
last=$(cat "$last_file" 2>/dev/null || echo $((now_min-60)))
[[ "$last" =~ ^[0-9]{1,12}$ ]] || last=$((now_min-60))
(( last <= now_min )) || last=$((now_min-60))
(( now_min-last <= 86400 )) || last=$((now_min-86400))

while IFS='|' read -r job group schedule delay timeout_s run_user script; do
    [[ -n "$job" && "${job:0:1}" != "#" ]] || continue
    [[ "$job" =~ ^[a-zA-Z0-9._-]+$ ]] || continue
    group_enabled "$group" || continue

    ov=$(override_value "$job" enabled 2>/dev/null || true)
    [[ -z "$ov" ]] || bool_true "$ov" || continue
    ov=$(override_value "$job" schedule 2>/dev/null || true); [[ -z "$ov" ]] || schedule=$ov
    ov=$(override_value "$job" random_delay 2>/dev/null || true); [[ -z "$ov" ]] || delay=$ov
    ov=$(override_value "$job" timeout 2>/dev/null || true); [[ -z "$ov" ]] || timeout_s=$ov
    ov=$(override_value "$job" user 2>/dev/null || true); [[ -z "$ov" ]] || run_user=$ov

    [[ "$delay" =~ ^[0-9]+$ && "$timeout_s" =~ ^[0-9]+$ ]] || continue
    [[ "$script" == /opt/server-tools/* && -f "$script" && ! -L "$script" ]] || continue
    id "$run_user" >/dev/null 2>&1 || continue

    job_state="$state_dir/jobs/$job"
    install -d -o root -g root -m 755 "$job_state"
    pending="$job_state/pending"
    last_slot=$(cat "$job_state/last-scheduled" 2>/dev/null || echo 0)
    [[ "$last_slot" =~ ^[0-9]{1,12}$ ]] || last_slot=0

    latest_match=0
    slot=$((last+60))
    while (( slot <= now_min )); do
        if cron_matches "$schedule" "$slot"; then latest_match=$slot; fi
        slot=$((slot+60))
    done

    if (( latest_match > 0 && latest_match > last_slot )); then
        pending_slot=0
        [[ -r "$pending" ]] && read -r pending_slot _ < "$pending" || true
        if [[ ! "$pending_slot" =~ ^[0-9]+$ || "$pending_slot" -lt "$latest_match" ]]; then
            if (( delay > 0 )); then
                rand=$(( (RANDOM << 15 | RANDOM) % (delay+1) ))
            else
                rand=0
            fi
            due=$((latest_match+rand))
            printf '%s %s\n' "$latest_match" "$due" > "$pending"
        fi
    fi

    if [[ -r "$pending" ]]; then
        read -r pending_slot due < "$pending" || true
        if [[ "$pending_slot" =~ ^[0-9]+$ && "$due" =~ ^[0-9]+$ ]] && (( now >= due )); then
            printf '%s\n' "$pending_slot" > "$job_state/last-scheduled"
            rm -f "$pending"
            if launch_job "$job" "$script" "$run_user" "$timeout_s" "$now"; then
                printf '%s\n' "$now" > "$job_state/last-launch"
                echo "server-tools scheduler: launched $job (slot=$pending_slot due=$due)"
            else
                echo "server-tools scheduler: failed to launch $job" >&2
            fi
        fi
    fi
done < "$jobs_file"

printf '%s\n' "$now_min" > "$last_file"
