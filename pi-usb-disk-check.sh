#!/usr/bin/env bash
# Intensive SMART / full-surface test for USB-SATA disks on a Raspberry Pi.
#
# Features:
#   - automatic discovery of whole USB disks (TYPE=disk, TRAN=usb)
#   - identity tracking by serial number, not /dev/sdX name
#   - fixed per-disk step numbering (x of y)
#   - MQTT notification after every completed/skipped step
#   - hourly MQTT progress for long SMART/write/read operations with ETA
#   - resumable chunked full-surface write/read tests
#   - short disconnect recovery window with serial re-detection
#   - persistent state/checkpoints for interrupted runs
#   - local MQTT queue when the sender is temporarily unavailable
#   - complete local protocol per disk
#
# WARNING: --destructive and automatic recovery after SMART surface problems can
# overwrite an entire USB disk. Never run this with USB disks attached that you
# do not intend to test.

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
TOTAL_STEPS=10
MODE="auto"                         # auto | force | never
MQTT_SENDER="${MQTT_SENDER:-/opt/send2mqtt.sh}"
SMART_POLL_SECONDS="${SMART_POLL_SECONDS:-60}"
PROGRESS_INTERVAL_SECONDS="${PROGRESS_INTERVAL_SECONDS:-3600}"
DISCONNECT_GRACE_SECONDS="${DISCONNECT_GRACE_SECONDS:-300}"
DISCONNECT_POLL_SECONDS="${DISCONNECT_POLL_SECONDS:-5}"
CHUNK_MIB="${CHUNK_MIB:-1024}"
MAX_SMART_RESTARTS="${MAX_SMART_RESTARTS:-3}"

usage() {
  cat <<'HELP'
Usage:
  pi-usb-disk-check.sh
      Auto mode. Runs SMART long tests and performs a destructive full-surface
      zero-write/read cycle only when the SMART test or surface indicators make
      that useful/necessary.

  pi-usb-disk-check.sh --destructive
      Forces the full-surface zero-write/read cycle for every discovered target.

  pi-usb-disk-check.sh --no-destructive
      SMART-only mode. Never overwrites a disk.

Optional environment variables:
  MQTT_SENDER=/opt/send2mqtt.sh
  SMART_POLL_SECONDS=60
  PROGRESS_INTERVAL_SECONDS=3600
  DISCONNECT_GRACE_SECONDS=300
  DISCONNECT_POLL_SECONDS=5
  CHUNK_MIB=1024
  MAX_SMART_RESTARTS=3

Targets are discovered once when the run starts. A target must be a whole block
DEVICE with TYPE=disk, TRAN=usb and a SMART-readable serial number.
HELP
}

case "${1:-}" in
  ""|--auto) MODE="auto" ;;
  --destructive|--force) MODE="force" ;;
  --no-destructive|--read-only) MODE="never" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

# Re-exec as root. The original user is retained via SUDO_USER for logs/MQTT.
if (( EUID != 0 )); then
  exec sudo "$0" "$@"
fi

RUN_USER="${SUDO_USER:-root}"
RUN_HOME="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
[[ -n "$RUN_HOME" ]] || RUN_HOME="/root"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"
LOGDIR="$RUN_HOME/smarttests"
STATE_DIR="$RUN_HOME/.local/state/pi-usb-disk-check"
QUEUE_DIR="$STATE_DIR/mqtt-queue"
RUN_MARKER="$STATE_DIR/run.incomplete"
mkdir -p "$LOGDIR" "$QUEUE_DIR"
chown -R "$RUN_USER:$RUN_GROUP" "$LOGDIR" "$STATE_DIR" 2>/dev/null || true

# Prevent concurrent destructive disk-check instances.
exec 9>/run/lock/pi-usb-disk-check.lock
if ! flock -n 9; then
  echo "Another pi-usb-disk-check instance is already running." >&2
  exit 1
fi

for cmd in smartctl lsblk blockdev awk grep sed dd flock date stat sync; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing command: $cmd" >&2
    exit 1
  }
done

# Do not require GNU dd byte-oriented flags. Raspberry Pi installations can
# provide a dd build without count_bytes/skip_bytes/seek_bytes. The surface I/O
# code below uses portable MiB block offsets and handles the final partial MiB
# separately, so ordinary coreutils/BusyBox-style dd is sufficient.

CURRENT_SERIAL=""
CURRENT_MODEL=""
CURRENT_STEP=0
CURRENT_STEP_NAME="setup"
CURRENT_DISK_INDEX=0
TARGET_COUNT=0
NORMAL_EXIT=0
EXIT_NOTICE_SENT=0

now() { date '+%Y-%m-%d %H:%M:%S %Z'; }
epoch() { date +%s; }

human_duration() {
  local s="${1:-0}" h m
  (( s < 0 )) && s=0
  h=$((s / 3600))
  m=$(((s % 3600) / 60))
  if (( h > 0 )); then
    printf '%dh %02dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

human_gb() {
  awk -v b="${1:-0}" 'BEGIN {printf "%.1f GB", b/1000000000}'
}

percent_of() {
  awk -v d="${1:-0}" -v t="${2:-0}" 'BEGIN {if (t<=0) printf "0.0"; else printf "%.1f", d*100/t}'
}

safe_name() {
  printf '%s' "$1" | sed 's#[/[:space:]]#_#g; s#[^A-Za-z0-9._-]#_#g; s/__*/_/g'
}

state_file_for() {
  printf '%s/%s.state\n' "$STATE_DIR" "$(safe_name "$1")"
}

write_state() {
  local serial="$1" model="$2" step="$3" phase="$4" offset="${5:-0}" total="${6:-0}"
  local f tmp
  f="$(state_file_for "$serial")"
  tmp="$f.tmp.$$"
  cat > "$tmp" <<EOF_STATE
SERIAL=$(printf '%q' "$serial")
MODEL=$(printf '%q' "$model")
STEP=$(printf '%q' "$step")
PHASE=$(printf '%q' "$phase")
OFFSET=$(printf '%q' "$offset")
TOTAL=$(printf '%q' "$total")
UPDATED=$(printf '%q' "$(now)")
EOF_STATE
  mv "$tmp" "$f"
  chown "$RUN_USER:$RUN_GROUP" "$f" 2>/dev/null || true
}

read_state() {
  local serial="$1" f
  f="$(state_file_for "$serial")"
  [[ -f "$f" ]] || return 1
  # shellcheck disable=SC1090
  source "$f"
  [[ "${SERIAL:-}" == "$serial" ]]
}

clear_state() {
  rm -f "$(state_file_for "$1")"
}

raw_mqtt_send() {
  local msg="$1"
  [[ -x "$MQTT_SENDER" ]] || return 1
  if [[ "$RUN_USER" != "root" ]]; then
    printf '%s\n' "$msg" | sudo -u "$RUN_USER" "$MQTT_SENDER"
  else
    printf '%s\n' "$msg" | "$MQTT_SENDER"
  fi
}

queue_mqtt() {
  local msg="$1" f
  f="$QUEUE_DIR/$(date +%s)-$$-$RANDOM.msg"
  printf '%s\n' "$msg" > "$f"
  chown "$RUN_USER:$RUN_GROUP" "$f" 2>/dev/null || true
}

flush_mqtt_queue() {
  local f msg
  shopt -s nullglob
  for f in "$QUEUE_DIR"/*.msg; do
    msg="$(cat "$f")"
    if raw_mqtt_send "$msg" >/dev/null 2>&1; then
      rm -f "$f"
    else
      shopt -u nullglob
      return 1
    fi
  done
  shopt -u nullglob
  return 0
}

mqtt_send() {
  local msg="$1"
  flush_mqtt_queue || true
  if ! raw_mqtt_send "$msg" >/dev/null 2>&1; then
    queue_mqtt "$msg"
    return 1
  fi
  return 0
}

context_prefix() {
  if [[ -n "$CURRENT_SERIAL" ]]; then
    printf 'Disk-Test [Platte %d/%d] – Step %d von %d\n%s / %s\n' \
      "$CURRENT_DISK_INDEX" "$TARGET_COUNT" "$CURRENT_STEP" "$TOTAL_STEPS" \
      "${CURRENT_MODEL:-UNKNOWN_MODEL}" "$CURRENT_SERIAL"
  else
    printf 'Disk-Test\n'
  fi
}

notify_error() {
  local detail="$1" msg
  msg="$(context_prefix)
FEHLER: $detail"
  mqtt_send "$msg" || true
  EXIT_NOTICE_SENT=1
}

step_start() {
  local n="$1" name="$2" log="$3"
  CURRENT_STEP="$n"
  CURRENT_STEP_NAME="$name"
  {
    echo
    echo "===== STEP $n/$TOTAL_STEPS START: $name ====="
    echo "[$(now)] Step $n von $TOTAL_STEPS gestartet: $name"
  } | tee -a "$log"
}

step_finish() {
  local n="$1" name="$2" result="$3" log="$4" status="${5:-abgeschlossen}" msg
  {
    echo "[$(now)] Step $n von $TOTAL_STEPS $status: $name – $result"
    echo "===== STEP $n/$TOTAL_STEPS END: $name ====="
  } | tee -a "$log"

  msg="$(context_prefix)
$status: $name
$result"
  mqtt_send "$msg" || true
}

step_skip() {
  local n="$1" name="$2" reason="$3" log="$4"
  CURRENT_STEP="$n"
  CURRENT_STEP_NAME="$name"
  step_finish "$n" "$name" "$reason" "$log" "übersprungen"
}

resolve_device() {
  local wanted="$1" name serial
  while read -r name; do
    [[ -n "$name" ]] || continue
    [[ -b "/dev/$name" ]] || continue
    serial="$(lsblk -dn -o SERIAL "/dev/$name" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ "$serial" == "$wanted" ]]; then
      printf '/dev/%s\n' "$name"
      return 0
    fi
  done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print $1}')
  return 1
}

smart() {
  local dev="$1"; shift
  smartctl -d sat "$@" "$dev"
}

get_model() {
  local dev="$1"
  smart "$dev" -i 2>/dev/null | awk -F: '/Device Model:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}'
}

get_serial() {
  local dev="$1"
  smart "$dev" -i 2>/dev/null | awk -F: '/Serial Number:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}'
}

attr_raw() {
  local dev="$1" id="$2"
  smart "$dev" -A 2>/dev/null | awk -v id="$id" '$1 == id {print $10; exit}'
}

num_or_zero() {
  local n="${1:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s\n' "$n" || printf '0\n'
}

health_value() {
  local dev="$1" out
  out="$(smart "$dev" -H 2>/dev/null || true)"
  if grep -q 'PASSED' <<<"$out"; then
    echo "PASSED"
  elif grep -qiE 'FAILED|FAIL' <<<"$out"; then
    echo "FAILED"
  else
    echo "UNKNOWN"
  fi
}

last_selftest_line() {
  local dev="$1"
  smart "$dev" -l selftest 2>/dev/null | awk '/^# 1/ {print; exit}'
}

long_test_ok() {
  local dev="$1" line
  line="$(last_selftest_line "$dev")"
  [[ "$line" == *"Completed without error"* ]]
}

smart_in_progress() {
  grep -qiE 'Self-test routine in progress|Self-test.*in progress' <<<"$1"
}

smart_remaining_percent() {
  local status="$1"
  awk '/% of test remaining/ {gsub(/[^0-9]/,"",$1); print $1; exit}' <<<"$status"
}

smart_recommended_seconds() {
  local dev="$1" m
  m="$(smart "$dev" -c 2>/dev/null | awk '/Extended self-test routine/ {getline; if (match($0,/\([[:space:]]*[0-9]+\)/)) {x=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",x); print x; exit}}')"
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  echo $((m * 60))
}

mounted_or_swap() {
  local dev="$1"
  if lsblk -nrpo MOUNTPOINTS "$dev" 2>/dev/null | grep -q '[^[:space:]]'; then
    return 0
  fi
  if command -v swapon >/dev/null 2>&1; then
    if swapon --noheadings --show=NAME 2>/dev/null | grep -qE "^${dev}([0-9]+|p[0-9]+)?$"; then
      return 0
    fi
  fi
  return 1
}

wait_for_device() {
  local serial="$1" reason="$2" log="$3"
  local start now_s dev
  start="$(epoch)"
  echo "[$(now)] Device $serial unavailable ($reason). Waiting up to ${DISCONNECT_GRACE_SECONDS}s..." | tee -a "$log"

  while true; do
    dev="$(resolve_device "$serial" 2>/dev/null || true)"
    if [[ -n "$dev" ]]; then
      echo "[$(now)] Device $serial returned as $dev; continuing." | tee -a "$log"
      return 0
    fi
    now_s="$(epoch)"
    if (( now_s - start >= DISCONNECT_GRACE_SECONDS )); then
      notify_error "USB-Gerät seit ${DISCONNECT_GRACE_SECONDS}s nicht erreichbar ($reason). Test kann nicht nahtlos fortgesetzt werden."
      return 1
    fi
    sleep "$DISCONNECT_POLL_SECONDS"
  done
}

ensure_device() {
  local serial="$1" reason="$2" log="$3" dev
  dev="$(resolve_device "$serial" 2>/dev/null || true)"
  if [[ -n "$dev" ]]; then
    printf '%s\n' "$dev"
    return 0
  fi
  wait_for_device "$serial" "$reason" "$log" || return 1
  resolve_device "$serial"
}

smart_hourly_progress() {
  local serial="$1" step="$2" step_name="$3" elapsed="$4" remaining="$5" recommended="$6"
  local progress estimated_total eta msg
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
  progress=$((100 - remaining))

  if (( progress <= 10 || elapsed < 900 )); then
    estimated_total="$recommended"
  else
    estimated_total=$(( elapsed * 100 / progress ))
    (( recommended > estimated_total )) && estimated_total="$recommended"
  fi
  (( estimated_total < elapsed )) && estimated_total="$elapsed"
  eta=$((estimated_total - elapsed))

  msg="$(context_prefix)
laufend: $step_name
Laufzeit: $(human_duration "$elapsed")
Fortschritt: ca. ${progress}%
Geschätzte Gesamtdauer: $(human_duration "$estimated_total")
Restzeit: ca. $(human_duration "$eta")"
  mqtt_send "$msg" || true
}

run_smart_long_test() {
  local serial="$1" log="$2" label="$3" step="$4"
  local dev status line start last_progress now_s elapsed remaining recommended
  local adopted=0 restarts=0 had_disconnect=0

  CURRENT_STEP="$step"
  CURRENT_STEP_NAME="$label"
  start="$(epoch)"
  last_progress="$start"

  while true; do
    dev="$(ensure_device "$serial" "vor SMART-Test" "$log")" || return 20
    status="$(smart "$dev" -c 2>&1 || true)"

    if smart_in_progress "$status"; then
      adopted=1
      echo "[$(now)] Existing SMART self-test detected; adopting it instead of starting another." | tee -a "$log"
    else
      echo "[$(now)] Starting SMART extended test on $dev." | tee -a "$log"
      if ! smart "$dev" -t long 2>&1 | tee -a "$log"; then
        # smartctl uses non-zero bitmasks for some SMART conditions. Re-check state before deciding.
        status="$(smart "$dev" -c 2>&1 || true)"
        if ! smart_in_progress "$status"; then
          notify_error "SMART Extended Test konnte nicht gestartet werden."
          return 21
        fi
      fi
    fi

    recommended="$(smart_recommended_seconds "$dev")"
    (( recommended > 0 )) || recommended=7200
    break
  done

  while true; do
    dev="$(resolve_device "$serial" 2>/dev/null || true)"
    if [[ -z "$dev" ]]; then
      had_disconnect=1
      if ! wait_for_device "$serial" "während SMART Extended Test" "$log"; then
        return 22
      fi
      dev="$(resolve_device "$serial" 2>/dev/null || true)"
    fi

    status="$(smart "$dev" -c 2>&1 || true)"
    now_s="$(epoch)"
    elapsed=$((now_s - start))

    if smart_in_progress "$status"; then
      remaining="$(smart_remaining_percent "$status")"
      [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
      echo "[$(now)] SMART test running: ${remaining}% remaining." >> "$log"

      if (( now_s - last_progress >= PROGRESS_INTERVAL_SECONDS )); then
        smart_hourly_progress "$serial" "$step" "$label" "$elapsed" "$remaining" "$recommended"
        last_progress="$now_s"
      fi
      sleep "$SMART_POLL_SECONDS"
      continue
    fi

    line="$(last_selftest_line "$dev")"
    echo "[$(now)] SMART self-test finished/state changed: ${line:-no self-test entry}" | tee -a "$log"

    if [[ "$line" == *"Completed without error"* ]]; then
      return 0
    fi

    # A real surface/read failure is a valid test result, not a program-flow failure.
    if grep -qiE 'read failure|Completed:.*failure|electrical failure|servo failure|handling damage' <<<"$line"; then
      return 10
    fi

    # Disconnect/power-cycle interruptions can be retried automatically.
    if (( had_disconnect )) || grep -qiE 'Interrupted|Aborted by host|Self-test routine was interrupted' <<<"$line"; then
      if (( restarts < MAX_SMART_RESTARTS )); then
        restarts=$((restarts + 1))
        had_disconnect=0
        echo "[$(now)] SMART test was interrupted; restarting ($restarts/$MAX_SMART_RESTARTS)." | tee -a "$log"
        mqtt_send "$(context_prefix)
SMART-Test wurde unterbrochen. Platte ist wieder erreichbar; Step wird automatisch neu gestartet ($restarts/$MAX_SMART_RESTARTS)." || true
        if smart "$dev" -t long 2>&1 | tee -a "$log"; then
          start="$(epoch)"
          last_progress="$start"
          recommended="$(smart_recommended_seconds "$dev")"
          (( recommended > 0 )) || recommended=7200
          continue
        fi
      fi
      notify_error "SMART-Test wurde unterbrochen und konnte nicht zuverlässig neu gestartet werden."
      return 23
    fi

    # Unknown termination. Report as program/test-flow error.
    notify_error "SMART-Test endete in einem unerwarteten Zustand: ${line:-kein Self-Test-Eintrag}"
    return 24
  done
}

save_io_checkpoint() {
  local serial="$1" model="$2" step="$3" phase="$4" offset="$5" total="$6"
  write_state "$serial" "$model" "$step" "$phase" "$offset" "$total"
}

chunked_surface_io() {
  local phase="$1" serial="$2" model="$3" step="$4" step_name="$5" log="$6"
  local dev total offset=0 chunk_bytes chunk_mib_bytes start_offset phase_start last_progress
  local now_s elapsed delta rate eta pct rc

  dev="$(ensure_device "$serial" "vor $step_name" "$log")" || return 30
  total="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )) || {
    notify_error "Größe der Platte konnte vor $step_name nicht ermittelt werden."
    return 31
  }

  if mounted_or_swap "$dev"; then
    notify_error "$dev oder eine Partition davon ist gemountet/als Swap aktiv; destruktiver Test wird aus Sicherheitsgründen nicht gestartet."
    return 32
  fi

  if read_state "$serial" 2>/dev/null; then
    if [[ "${PHASE:-}" == "$phase" && "${TOTAL:-0}" == "$total" && "${OFFSET:-0}" =~ ^[0-9]+$ ]]; then
      offset="$OFFSET"
      (( offset > total )) && offset=0
      if (( offset > 0 )); then
        echo "[$(now)] Resuming $phase from checkpoint $offset/$total bytes." | tee -a "$log"
        mqtt_send "$(context_prefix)
$step_name wird aus Checkpoint fortgesetzt.
Fortschritt beim Wiederanlauf: $(human_gb "$offset") / $(human_gb "$total") ($(percent_of "$offset" "$total")%)" || true
      fi
    fi
  fi

  chunk_mib_bytes=$((CHUNK_MIB * 1024 * 1024))
  start_offset="$offset"
  phase_start="$(epoch)"
  last_progress="$phase_start"
  save_io_checkpoint "$serial" "$model" "$step" "$phase" "$offset" "$total"

  while (( offset < total )); do
    dev="$(ensure_device "$serial" "während $step_name" "$log")" || return 33
    chunk_bytes="$chunk_mib_bytes"
    (( offset + chunk_bytes > total )) && chunk_bytes=$((total - offset))

    rc=0
    # Use MiB-based skip/seek so the script also works with dd implementations
    # that do not support GNU's count_bytes/skip_bytes/seek_bytes flags.
    # Checkpoints are chunk-aligned; only the final partial MiB needs bs=1.
    local mib=1048576 full_mib tail_bytes block_offset tail_offset
    full_mib=$((chunk_bytes / mib))
    tail_bytes=$((chunk_bytes % mib))
    block_offset=$((offset / mib))

    if [[ "$phase" == "write" ]]; then
      if (( full_mib > 0 )); then
        dd if=/dev/zero of="$dev" bs=1M count="$full_mib" seek="$block_offset" \
          conv=notrunc,fsync status=none || rc=$?
      fi
      if (( rc == 0 && tail_bytes > 0 )); then
        tail_offset=$((offset + full_mib * mib))
        dd if=/dev/zero of="$dev" bs=1 count="$tail_bytes" seek="$tail_offset" \
          conv=notrunc,fsync status=none || rc=$?
      fi
    else
      if (( full_mib > 0 )); then
        dd if="$dev" of=/dev/null bs=1M skip="$block_offset" count="$full_mib" \
          status=none || rc=$?
      fi
      if (( rc == 0 && tail_bytes > 0 )); then
        tail_offset=$((offset + full_mib * mib))
        dd if="$dev" of=/dev/null bs=1 skip="$tail_offset" count="$tail_bytes" \
          status=none || rc=$?
      fi
    fi

    if (( rc != 0 )); then
      echo "[$(now)] $step_name chunk failed at offset $offset (rc=$rc)." | tee -a "$log"
      if wait_for_device "$serial" "$step_name nach I/O-Fehler" "$log"; then
        echo "[$(now)] Device returned; retrying current chunk from checkpoint." | tee -a "$log"
        continue
      fi
      notify_error "$step_name abgebrochen bei $(human_gb "$offset") / $(human_gb "$total"). Platte kam innerhalb der Wartezeit nicht zuverlässig zurück."
      return 34
    fi

    offset=$((offset + chunk_bytes))
    save_io_checkpoint "$serial" "$model" "$step" "$phase" "$offset" "$total"

    now_s="$(epoch)"
    if (( now_s - last_progress >= PROGRESS_INTERVAL_SECONDS )); then
      elapsed=$((now_s - phase_start))
      delta=$((offset - start_offset))
      if (( elapsed > 0 && delta > 0 )); then
        rate=$((delta / elapsed))
        eta=$(((total - offset) / rate))
      else
        rate=0
        eta=0
      fi
      pct="$(percent_of "$offset" "$total")"
      mqtt_send "$(context_prefix)
laufend: $step_name
Laufzeit seit diesem Start: $(human_duration "$elapsed")
Fortschritt: $(human_gb "$offset") / $(human_gb "$total") (${pct}%)
Durchschnitt: $(awk -v r="$rate" 'BEGIN {printf "%.1f MB/s", r/1000000}')
Restzeit: ca. $(human_duration "$eta")" || true
      last_progress="$now_s"
    fi
  done

  [[ "$phase" == "write" ]] && sync
  return 0
}

append_information_section() {
  local dev="$1"
  smart "$dev" -a 2>/dev/null | awk '
    /=== START OF INFORMATION SECTION ===/ {p=1}
    /=== START OF READ SMART DATA SECTION ===/ {p=0}
    p {print}
  '
}

discover_target_serials() {
  local name type tran dev serial
  while read -r name type tran; do
    [[ "$type" == "disk" && "$tran" == "usb" ]] || continue
    dev="/dev/$name"
    [[ -b "$dev" ]] || continue
    serial="$(smartctl -d sat -i "$dev" 2>/dev/null | awk -F: '/Serial Number:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}')"
    [[ -n "$serial" ]] || continue
    printf '%s\n' "$serial"
  done < <(lsblk -dn -o NAME,TYPE,TRAN)
}

process_disk() {
  local expected_serial="$1" index="$2"
  local dev model serial fname log initial_long_rc=0 final_long_rc=0
  local pending uncorrect realloc crc health last destructive_needed=0
  local result_grade summary info resume_phase="" resume_offset=0

  CURRENT_DISK_INDEX="$index"
  CURRENT_SERIAL="$expected_serial"
  CURRENT_MODEL="UNKNOWN_MODEL"

  dev="$(ensure_device "$expected_serial" "beim Start der Platte" /dev/null)" || return 1
  model="$(get_model "$dev")"
  serial="$(get_serial "$dev")"
  [[ -n "$model" ]] || model="UNKNOWN_MODEL"
  [[ -n "$serial" ]] || serial="$expected_serial"
  CURRENT_MODEL="$model"

  fname="$(safe_name "$model")-$(safe_name "$serial").txt"
  log="$LOGDIR/$fname"

  if read_state "$serial" 2>/dev/null; then
    resume_phase="${PHASE:-}"
    resume_offset="${OFFSET:-0}"
  fi

  {
    echo "============================================================"
    echo "Disk test protocol"
    echo "Start: $(now)"
    echo "Mode: $MODE"
    echo "Device at start: $dev"
    echo "Model: $model"
    echo "Serial: $serial"
    if [[ -n "$resume_phase" ]]; then
      echo "Resume state detected: phase=$resume_phase offset=$resume_offset"
    fi
    echo "============================================================"
  } > "$log"
  chown "$RUN_USER:$RUN_GROUP" "$log" 2>/dev/null || true

  # STEP 1: identity/inventory
  step_start 1 "Gerät identifizieren und Inventar erfassen" "$log"
  {
    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS "$dev" || true
    echo
    smart "$dev" -i 2>&1 || true
  } >> "$log"
  step_finish 1 "Gerät identifizieren und Inventar erfassen" "Gerät erkannt als $dev; Modell=$model; Serial=$serial" "$log"

  # STEP 2: initial SMART snapshot
  step_start 2 "Initiale SMART-Daten erfassen" "$log"
  {
    echo "===== INITIAL SMARTCTL -x ====="
    smart "$dev" -x 2>&1 || true
  } >> "$log"
  step_finish 2 "Initiale SMART-Daten erfassen" "SMART-Ausgangszustand vollständig protokolliert." "$log"

  # Resume logic after an interrupted destructive phase: initial SMART test/evaluation
  # were already completed in the previous run, so avoid repeating hours of testing.
  if [[ "$resume_phase" == "write" || "$resume_phase" == "read" || "$resume_phase" == "final_smart" ]]; then
    step_skip 3 "Initialer SMART Extended Test" "Wiederanlauf aus vorherigem Checkpoint ($resume_phase); der initiale Test wurde bereits abgeschlossen." "$log"
    step_skip 4 "SMART-Ergebnis bewerten / Volltest entscheiden" "Wiederanlauf aus vorherigem Checkpoint; Volltest war bereits ausgewählt." "$log"
    destructive_needed=1
  else
    # STEP 3: initial long SMART test
    step_start 3 "Initialer SMART Extended Test" "$log"
    write_state "$serial" "$model" 3 "initial_smart" 0 0
    run_smart_long_test "$serial" "$log" "Initialer SMART Extended Test" 3 || initial_long_rc=$?
    dev="$(ensure_device "$serial" "nach initialem SMART-Test" "$log")" || return 1
    if (( initial_long_rc == 0 )); then
      step_finish 3 "Initialer SMART Extended Test" "SMART Extended Test ohne Fehler abgeschlossen." "$log"
    elif (( initial_long_rc == 10 )); then
      step_finish 3 "Initialer SMART Extended Test" "SMART Extended Test meldet einen Oberflächen-/Lesefehler; weitere Prüfung erforderlich." "$log" "abgeschlossen mit Befund"
    else
      step_finish 3 "Initialer SMART Extended Test" "Testablauf konnte nicht zuverlässig abgeschlossen werden (rc=$initial_long_rc)." "$log" "FEHLER"
      return 1
    fi

    # STEP 4: evaluation
    step_start 4 "SMART-Ergebnis bewerten / Volltest entscheiden" "$log"
    pending="$(num_or_zero "$(attr_raw "$dev" 197)")"
    uncorrect="$(num_or_zero "$(attr_raw "$dev" 198)")"
    destructive_needed=0
    if (( initial_long_rc == 10 || pending > 0 || uncorrect > 0 )); then
      destructive_needed=1
    fi
    if [[ "$MODE" == "force" ]]; then
      destructive_needed=1
    elif [[ "$MODE" == "never" ]]; then
      destructive_needed=0
    fi
    step_finish 4 "SMART-Ergebnis bewerten / Volltest entscheiden" \
      "Long-Test-RC=$initial_long_rc, Pending=$pending, Uncorrectable=$uncorrect, Modus=$MODE → Volltest=$( ((destructive_needed)) && echo ja || echo nein )." "$log"
  fi

  # STEP 5: write
  if (( destructive_needed )); then
    step_start 5 "Komplette Oberfläche mit Nullen beschreiben" "$log"
    if [[ "$resume_phase" == "read" || "$resume_phase" == "final_smart" ]]; then
      step_finish 5 "Komplette Oberfläche mit Nullen beschreiben" "Bereits in vorherigem Lauf vollständig abgeschlossen." "$log"
    else
      if chunked_surface_io "write" "$serial" "$model" 5 "Vollständiger Schreibtest" "$log"; then
        step_finish 5 "Komplette Oberfläche mit Nullen beschreiben" "Gesamte Platte erfolgreich beschrieben; Checkpoints aktiviert." "$log"
      else
        step_finish 5 "Komplette Oberfläche mit Nullen beschreiben" "Schreibtest konnte nicht vollständig abgeschlossen werden; Checkpoint bleibt erhalten." "$log" "FEHLER"
        return 1
      fi
    fi
  else
    step_skip 5 "Komplette Oberfläche mit Nullen beschreiben" "Nicht erforderlich bzw. durch --no-destructive deaktiviert." "$log"
  fi

  # STEP 6: read-back
  if (( destructive_needed )); then
    step_start 6 "Komplette Oberfläche lesen" "$log"
    if [[ "$resume_phase" == "final_smart" ]]; then
      step_finish 6 "Komplette Oberfläche lesen" "Bereits in vorherigem Lauf vollständig abgeschlossen." "$log"
    else
      # Start read from 0 unless an existing read checkpoint is present.
      if [[ "$resume_phase" != "read" ]]; then
        write_state "$serial" "$model" 6 "read" 0 "$(blockdev --getsize64 "$(resolve_device "$serial")")"
      fi
      if chunked_surface_io "read" "$serial" "$model" 6 "Vollständiger Lesetest" "$log"; then
        step_finish 6 "Komplette Oberfläche lesen" "Gesamte Platte erfolgreich gelesen; keine I/O-Abbrüche." "$log"
      else
        step_finish 6 "Komplette Oberfläche lesen" "Lesetest konnte nicht vollständig abgeschlossen werden; Checkpoint bleibt erhalten." "$log" "FEHLER"
        return 1
      fi
    fi
  else
    step_skip 6 "Komplette Oberfläche lesen" "Nicht erforderlich, da kein destruktiver Volltest ausgewählt wurde." "$log"
  fi

  # STEP 7: final SMART long after destructive cycle
  if (( destructive_needed )); then
    step_start 7 "Finaler SMART Extended Test" "$log"
    write_state "$serial" "$model" 7 "final_smart" 0 0
    run_smart_long_test "$serial" "$log" "Finaler SMART Extended Test" 7 || final_long_rc=$?
    if (( final_long_rc == 0 )); then
      step_finish 7 "Finaler SMART Extended Test" "SMART Extended Test nach Volltest ohne Fehler abgeschlossen." "$log"
    elif (( final_long_rc == 10 )); then
      step_finish 7 "Finaler SMART Extended Test" "SMART Extended Test meldet weiterhin einen Oberflächen-/Lesefehler." "$log" "abgeschlossen mit Befund"
    else
      step_finish 7 "Finaler SMART Extended Test" "Testablauf konnte nicht zuverlässig abgeschlossen werden (rc=$final_long_rc)." "$log" "FEHLER"
      return 1
    fi
  else
    step_skip 7 "Finaler SMART Extended Test" "Kein Volltest durchgeführt; initialer Extended Test ist maßgeblich." "$log"
    final_long_rc="$initial_long_rc"
  fi

  # STEP 8: final SMART snapshot
  step_start 8 "Finale SMART-Daten erfassen" "$log"
  dev="$(ensure_device "$serial" "vor finaler SMART-Erfassung" "$log")" || return 1
  {
    echo
    echo "===== FINAL SMARTCTL -x ====="
    smart "$dev" -x 2>&1 || true
  } >> "$log"
  step_finish 8 "Finale SMART-Daten erfassen" "Finaler SMART-Zustand vollständig protokolliert." "$log"

  # STEP 9: final evaluation
  step_start 9 "Endergebnis bewerten" "$log"
  health="$(health_value "$dev")"
  realloc="$(num_or_zero "$(attr_raw "$dev" 5)")"
  pending="$(num_or_zero "$(attr_raw "$dev" 197)")"
  uncorrect="$(num_or_zero "$(attr_raw "$dev" 198)")"
  crc="$(num_or_zero "$(attr_raw "$dev" 199)")"
  last="$(last_selftest_line "$dev")"

  if (( final_long_rc == 0 )) && [[ "$health" == "PASSED" ]] && (( pending == 0 && uncorrect == 0 )); then
    if (( realloc == 0 && crc == 0 )); then
      result_grade="OK"
    else
      result_grade="WARN"
    fi
  else
    result_grade="FAIL"
  fi

  summary="$result_grade: Long=$( ((final_long_rc==0)) && echo OK || echo FEHLER ), SMART=$health, Realloc=$realloc, Pending=$pending, Uncorr=$uncorrect, CRC=$crc, Volltest=$( ((destructive_needed)) && echo ja || echo nein )"
  {
    echo
    echo "===== FINAL SHORT RESULT ====="
    echo "$summary"
    echo "Last self-test: ${last:-none}"
  } >> "$log"
  step_finish 9 "Endergebnis bewerten" "$summary" "$log"

  # STEP 10: persist/report final information section
  step_start 10 "Protokoll abschließen und Endbericht senden" "$log"
  info="$(append_information_section "$dev")"
  {
    echo
    echo "===== FINAL INFORMATION SECTION ====="
    echo "$info"
    echo "End: $(now)"
  } >> "$log"
  chown "$RUN_USER:$RUN_GROUP" "$log" 2>/dev/null || true

  mqtt_send "$(context_prefix)
Endbericht
$info
ERGEBNIS: $summary
Protokoll: $log" || true
  step_finish 10 "Protokoll abschließen und Endbericht senden" "Lokales Protokoll abgeschlossen; vollständige Information Section und Kurzbewertung an MQTT übergeben." "$log"

  clear_state "$serial"
  return 0
}

handle_signal() {
  local sig="$1"
  notify_error "Script durch Signal $sig abgebrochen. Checkpoint/State bleibt für einen späteren Wiederanlauf erhalten."
  echo "STATUS=aborted_by_signal" >> "$RUN_MARKER" 2>/dev/null || true
  exit 128
}

handle_exit() {
  local rc=$?
  if (( NORMAL_EXIT )); then
    rm -f "$RUN_MARKER"
    flush_mqtt_queue || true
    return
  fi
  if (( rc != 0 )) && (( EXIT_NOTICE_SENT == 0 )); then
    notify_error "Script endete unerwartet mit Exit-Code $rc. State/Checkpoint bleibt erhalten."
  fi
}

trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
trap 'handle_signal HUP' HUP
trap handle_exit EXIT

# Report an unclean previous run before overwriting the marker.
if [[ -f "$RUN_MARKER" ]]; then
  previous="$(cat "$RUN_MARKER" 2>/dev/null || true)"
  mqtt_send "Disk-Test WARNUNG
Vorheriger Lauf wurde nicht sauber abgeschlossen oder der Pi/das USB-Gerät verlor unerwartet Strom.
Persistenter State/Checkpoint wird beim neuen Lauf berücksichtigt.
Letzter Marker:
$previous" || true
fi

cat > "$RUN_MARKER" <<EOF_MARKER
START=$(now)
USER=$RUN_USER
MODE=$MODE
PID=$$
EOF_MARKER
chown "$RUN_USER:$RUN_GROUP" "$RUN_MARKER" 2>/dev/null || true

mapfile -t TARGET_SERIALS < <(discover_target_serials | awk '!seen[$0]++')
TARGET_COUNT="${#TARGET_SERIALS[@]}"

if (( TARGET_COUNT == 0 )); then
  notify_error "Keine geeignete USB-SATA-Platte gefunden (TYPE=disk, TRAN=usb, SMART-Serial lesbar)."
  exit 1
fi

mqtt_send "Disk-Test gestartet
Gefundene USB-Platten: $TARGET_COUNT
Modus: $MODE
Step-System: $TOTAL_STEPS Schritte pro Platte
Stündliche Fortschrittsmeldungen: aktiv
Disconnect-Wartezeit: ${DISCONNECT_GRACE_SECONDS}s
Chunk-Größe Schreib/Lesetest: ${CHUNK_MIB} MiB" || true

echo "Discovered $TARGET_COUNT USB disk(s) for this run:"
for serial in "${TARGET_SERIALS[@]}"; do
  dev="$(resolve_device "$serial" 2>/dev/null || true)"
  if [[ -n "$dev" ]]; then
    printf '  %s  %s  %s\n' "$dev" "$(get_model "$dev" 2>/dev/null || echo UNKNOWN_MODEL)" "$serial"
  else
    printf '  ?  ?  %s\n' "$serial"
  fi
done

success_count=0
fail_count=0
index=0
for serial in "${TARGET_SERIALS[@]}"; do
  index=$((index + 1))
  if process_disk "$serial" "$index"; then
    success_count=$((success_count + 1))
  else
    fail_count=$((fail_count + 1))
    mqtt_send "$(context_prefix)
Platte konnte nicht vollständig abgeschlossen werden. State/Checkpoint bleibt für Wiederanlauf erhalten." || true
  fi
done

mqtt_send "Disk-Test Gesamtlauf abgeschlossen
Platten gesamt: $TARGET_COUNT
Erfolgreich abgeschlossen: $success_count
Nicht vollständig abgeschlossen: $fail_count
Logs: $LOGDIR" || true

if (( fail_count == 0 )); then
  NORMAL_EXIT=1
  exit 0
else
  # The run itself finished, but at least one disk remains incomplete. Keep marker/state.
  EXIT_NOTICE_SENT=1
  exit 1
fi