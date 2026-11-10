#!/usr/bin/env bash
# Intensive SMART / full-surface test for USB-SATA disks on a Raspberry Pi.
# At startup it automatically discovers all whole block devices with TRAN=usb
# that expose a usable SMART serial number through smartctl -d sat.
# The discovered serial numbers are frozen for the run and re-checked before any destructive step.
# WARNING: In auto/force mode this script may overwrite an entire eligible USB disk with zeros.

set -u

MQTT_SENDER="/opt/send2mqtt.sh"
POLL_SECONDS=60
MODE="auto"   # auto | force | never

case "${1:-}" in
  "") ;;
  --auto) MODE="auto" ;;
  --destructive|--force) MODE="force" ;;
  --no-destructive|--read-only) MODE="never" ;;
  -h|--help)
    cat <<'HELP'
Usage:
  pi-usb-disk-check.sh                   # default: destructive cycle only if useful/necessary
  pi-usb-disk-check.sh --destructive     # force full zero-write + full read on all discovered USB disks
  pi-usb-disk-check.sh --no-destructive  # SMART long tests only; never writes whole disks

Targets are discovered automatically from whole USB disks present when the script starts.
Their serial numbers are frozen for the run; destructive work is refused if identity changes.
HELP
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 2
    ;;
esac

# Re-exec as root. SUDO_USER is then used to select the real user's home for logs.
if (( EUID != 0 )); then
  exec sudo "$0" "$@"
fi

RUN_USER="${SUDO_USER:-root}"
RUN_HOME="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
[[ -n "$RUN_HOME" ]] || RUN_HOME="/root"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"
LOGDIR="$RUN_HOME/smarttests"
mkdir -p "$LOGDIR"
chown "$RUN_USER:$RUN_GROUP" "$LOGDIR" 2>/dev/null || true

# Prevent two destructive test scripts from running at the same time.
exec 9>/run/lock/pi-usb-disk-check.lock
if ! flock -n 9; then
  echo "Another pi-usb-disk-check instance is already running." >&2
  exit 1
fi

for cmd in smartctl lsblk blockdev awk grep sed dd flock; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing command: $cmd" >&2
    exit 1
  }
done

MQTT_TMP="$(mktemp)"
trap 'rm -f "$MQTT_TMP"' EXIT

now() { date '+%Y-%m-%d %H:%M:%S %Z'; }

resolve_device() {
  local wanted="$1" d serial
  for d in /dev/sd? /dev/sd??; do
    [[ -b "$d" ]] || continue
    serial="$(lsblk -dn -o SERIAL "$d" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ "$serial" == "$wanted" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
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

safe_name() {
  printf '%s' "$1" | sed 's#[/[:space:]]#_#g; s#[^A-Za-z0-9._-]#_#g; s/__*/_/g'
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

assert_serial() {
  local dev="$1" expected="$2" current
  current="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$current" != "$expected" ]]; then
    echo "SAFETY STOP: $dev is no longer serial $expected (now: ${current:-unknown})." >&2
    return 1
  fi
  return 0
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

wait_for_long_test() {
  local dev="$1" log="$2" status
  while true; do
    status="$(smart "$dev" -c 2>&1 || true)"
    {
      echo "[$(now)] SMART test status:"
      echo "$status" | grep -A2 -i 'Self-test execution status' || true
    } >> "$log"

    if grep -qiE 'Self-test routine in progress|Self-test.*in progress' <<<"$status"; then
      printf '[%s] %s: SMART long test still running...\n' "$(now)" "$dev"
      sleep "$POLL_SECONDS"
    else
      break
    fi
  done
}

run_long_test() {
  local dev="$1" log="$2" label="$3"
  {
    echo
    echo "===== $label: SMART EXTENDED TEST START ====="
    echo "[$(now)] Command: smartctl -d sat -t long $dev"
  } | tee -a "$log"

  smart "$dev" -t long 2>&1 | tee -a "$log" || true
  sleep 2
  wait_for_long_test "$dev" "$log"

  {
    echo "[$(now)] Self-test log after $label:"
    smart "$dev" -l selftest 2>&1 || true
    echo "===== $label: SMART EXTENDED TEST END ====="
  } | tee -a "$log"
}

full_zero_write_and_read() {
  local dev="$1" serial="$2" log="$3" bytes rcw rcr current_dev

  current_dev="$(resolve_device "$serial" || true)"
  if [[ -z "$current_dev" ]]; then
    echo "Destructive phase aborted: serial $serial is no longer present." | tee -a "$log"
    return 2
  fi
  dev="$current_dev"

  if ! assert_serial "$dev" "$serial"; then
    echo "Destructive phase aborted: device identity changed." | tee -a "$log"
    return 2
  fi

  if mounted_or_swap "$dev"; then
    {
      echo "[$(now)] DESTRUCTIVE PHASE SKIPPED: $dev or one of its partitions is mounted/in swap."
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$dev" || true
    } | tee -a "$log"
    return 3
  fi

  bytes="$(blockdev --getsize64 "$dev")"
  {
    echo
    echo "===== DESTRUCTIVE FULL-SURFACE CYCLE START ====="
    echo "[$(now)] WARNING: overwriting entire $dev ($serial) with zeros."
    echo "[$(now)] Size: $bytes bytes"
  } | tee -a "$log"

  dd if=/dev/zero of="$dev" bs=16M count="$bytes" iflag=count_bytes status=progress conv=fsync 2>&1 | tee -a "$log"
  rcw=${PIPESTATUS[0]}
  sync
  echo "[$(now)] Full zero-write exit code: $rcw" | tee -a "$log"

  current_dev="$(resolve_device "$serial" || true)"
  if [[ -z "$current_dev" ]]; then
    echo "SAFETY STOP before read-back: serial $serial disappeared." | tee -a "$log"
    return 4
  fi
  dev="$current_dev"
  if ! assert_serial "$dev" "$serial"; then
    echo "SAFETY STOP before read-back: device identity changed." | tee -a "$log"
    return 4
  fi

  dd if="$dev" of=/dev/null bs=16M status=progress 2>&1 | tee -a "$log"
  rcr=${PIPESTATUS[0]}
  echo "[$(now)] Full read-back exit code: $rcr" | tee -a "$log"

  echo "===== DESTRUCTIVE FULL-SURFACE CYCLE END =====" | tee -a "$log"

  [[ "$rcw" -eq 0 && "$rcr" -eq 0 ]]
}

append_final_mqtt_block() {
  local dev="$1" model="$2" serial="$3" summary="$4"
  local info
  info="$(smart "$dev" -a 2>/dev/null | awk '
    /=== START OF INFORMATION SECTION ===/ {p=1}
    /=== START OF READ SMART DATA SECTION ===/ {p=0}
    p {print}
  ')"

  {
    echo "=== $model / $serial ==="
    echo "$info"
    echo "ERGEBNIS: $summary"
    echo
  } >> "$MQTT_TMP"
}

process_disk() {
  local expected_serial="$1" dev model serial fname log
  local pending uncorrect realloc crc health last longok destructive_needed=0 destructive_done="nein"
  local result_grade summary

  dev="$(resolve_device "$expected_serial" || true)"
  if [[ -z "$dev" ]]; then
    echo "[$(now)] Disk with serial $expected_serial not found."
    {
      echo "=== Serial $expected_serial ==="
      echo "ERGEBNIS: FAIL: Platte nicht gefunden"
      echo
    } >> "$MQTT_TMP"
    return 1
  fi

  model="$(get_model "$dev")"
  serial="$(get_serial "$dev")"
  [[ -n "$model" ]] || model="UNKNOWN_MODEL"
  [[ -n "$serial" ]] || serial="$expected_serial"

  fname="$(safe_name "$model")-$(safe_name "$serial").txt"
  log="$LOGDIR/$fname"

  {
    echo "============================================================"
    echo "Disk test protocol"
    echo "Start: $(now)"
    echo "Mode: $MODE"
    echo "Device at start: $dev"
    echo "Model: $model"
    echo "Serial: $serial"
    echo "============================================================"
    echo
    echo "===== LSBLK AT START ====="
    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS "$dev" || true
    echo
    echo "===== INITIAL SMARTCTL -x ====="
    smart "$dev" -x 2>&1 || true
  } > "$log"
  chown "$RUN_USER:$RUN_GROUP" "$log" 2>/dev/null || true

  echo
  echo "[$(now)] Testing $model / $serial on $dev"
  echo "[$(now)] Log: $log"

  run_long_test "$dev" "$log" "INITIAL"

  pending="$(num_or_zero "$(attr_raw "$dev" 197)")"
  uncorrect="$(num_or_zero "$(attr_raw "$dev" 198)")"

  if ! long_test_ok "$dev" || (( pending > 0 || uncorrect > 0 )); then
    destructive_needed=1
  fi

  if [[ "$MODE" == "force" ]]; then
    destructive_needed=1
  elif [[ "$MODE" == "never" ]]; then
    destructive_needed=0
  fi

  if (( destructive_needed )); then
    {
      echo
      echo "[$(now)] Destructive cycle selected:"
      echo "  long-test-ok=$(long_test_ok "$dev" && echo yes || echo no)"
      echo "  Current_Pending_Sector=$pending"
      echo "  Offline_Uncorrectable=$uncorrect"
    } | tee -a "$log"

    if full_zero_write_and_read "$dev" "$serial" "$log"; then
      destructive_done="ja, write+read OK"
    else
      destructive_done="versucht/übersprungen; siehe Log"
    fi

    # After a full write/read, run another long SMART test so the final status reflects the whole surface.
    dev="$(resolve_device "$serial" || true)"
    if [[ -n "$dev" ]] && assert_serial "$dev" "$serial"; then
      run_long_test "$dev" "$log" "FINAL AFTER FULL-SURFACE CYCLE"
    else
      echo "[$(now)] Final SMART test skipped: serial $serial is no longer available." | tee -a "$log"
    fi
  else
    echo "[$(now)] No destructive full-surface cycle required in mode '$MODE'." | tee -a "$log"
  fi

  dev="$(resolve_device "$serial" || true)"
  if [[ -z "$dev" ]]; then
    echo "[$(now)] FAIL: serial $serial disappeared before final SMART collection." | tee -a "$log"
    {
      echo "=== $model / $serial ==="
      echo "ERGEBNIS: FAIL: Platte vor Abschluss nicht mehr gefunden"
      echo
    } >> "$MQTT_TMP"
    return 1
  fi

  {
    echo
    echo "===== FINAL SMARTCTL -x ====="
    smart "$dev" -x 2>&1 || true
    echo
    echo "End: $(now)"
  } >> "$log"

  health="$(health_value "$dev")"
  realloc="$(num_or_zero "$(attr_raw "$dev" 5)")"
  pending="$(num_or_zero "$(attr_raw "$dev" 197)")"
  uncorrect="$(num_or_zero "$(attr_raw "$dev" 198)")"
  crc="$(num_or_zero "$(attr_raw "$dev" 199)")"
  last="$(last_selftest_line "$dev")"

  if long_test_ok "$dev" && [[ "$health" == "PASSED" ]] && (( pending == 0 && uncorrect == 0 )); then
    if (( realloc == 0 )); then
      result_grade="OK"
    else
      result_grade="WARN"
    fi
  else
    result_grade="FAIL"
  fi

  summary="$result_grade: Long=$(long_test_ok "$dev" && echo OK || echo FEHLER), SMART=$health, Realloc=$realloc, Pending=$pending, Uncorr=$uncorrect, CRC=$crc, Volltest=$destructive_done"

  {
    echo
    echo "===== FINAL SHORT RESULT ====="
    echo "$summary"
    echo "Last self-test: ${last:-none}"
  } >> "$log"

  chown "$RUN_USER:$RUN_GROUP" "$log" 2>/dev/null || true
  append_final_mqtt_block "$dev" "$model" "$serial" "$summary"

  echo "[$(now)] $model / $serial -> $summary"
}


# Discover eligible whole USB disks once at startup.
# Only devices with TYPE=disk, TRAN=usb and a SMART-readable serial are accepted.
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

mapfile -t TARGET_SERIALS < <(discover_target_serials | awk '!seen[$0]++')

if (( ${#TARGET_SERIALS[@]} == 0 )); then
  echo "No eligible USB-SATA disks found (TYPE=disk, TRAN=usb, SMART serial readable)." >&2
  exit 1
fi

echo "Discovered ${#TARGET_SERIALS[@]} USB disk(s) for this run:"
for serial in "${TARGET_SERIALS[@]}"; do
  dev="$(resolve_device "$serial" 2>/dev/null || true)"
  if [[ -n "$dev" ]]; then
    printf '  %s  %s  %s\n' "$dev" "$(get_model "$dev" 2>/dev/null || echo UNKNOWN_MODEL)" "$serial"
  else
    printf '  ?  ?  %s\n' "$serial"
  fi
done

for serial in "${TARGET_SERIALS[@]}"; do
  process_disk "$serial" || true
done

# Send one combined message after all discovered disks have finished.
if [[ -f "$MQTT_SENDER" ]]; then
  echo "[$(now)] Sending final report via $MQTT_SENDER"
  if [[ "$RUN_USER" != "root" ]]; then
    sudo -u "$RUN_USER" "$MQTT_SENDER" < "$MQTT_TMP" || echo "MQTT send failed." >&2
  else
    "$MQTT_SENDER" < "$MQTT_TMP" || echo "MQTT send failed." >&2
  fi
else
  echo "[$(now)] MQTT sender not found: $MQTT_SENDER" >&2
  echo "Final MQTT payload was:"
  cat "$MQTT_TMP"
fi

echo
echo "Finished. Logs are in: $LOGDIR"
