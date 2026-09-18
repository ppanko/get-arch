#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
readonly LAUNCHER_SOURCE=archiso/get-arch-install

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

new_case() {
  CASE_DIR=$(mktemp -d)
  export CASE_DIR
  export LOG_DIR="$CASE_DIR/log"
  mkdir -p "$CASE_DIR/bin" "$LOG_DIR"
  printf '{}\n' > "$CASE_DIR/preset.json"

  cp "$LAUNCHER_SOURCE" "$CASE_DIR/launcher"
  sed -i \
    -e "s#/run/get-arch-install.started#$CASE_DIR/sentinel#g" \
    -e "s#/run/get-arch.json#$CASE_DIR/runtime.json#g" \
    -e "s#/root/get-arch.json#$CASE_DIR/preset.json#g" \
    -e "s#/root/get-arch-disk-config#$CASE_DIR/helper#g" \
    "$CASE_DIR/launcher"
  chmod +x "$CASE_DIR/launcher"

  cat > "$CASE_DIR/bin/tty" <<'SH'
#!/usr/bin/env bash
printf '/dev/tty1\n'
SH
  cat > "$CASE_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$CASE_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
count_file="$LOG_DIR/curl-count"
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if (( count <= ${CURL_FAIL_COUNT:-0} )); then
  exit 1
fi
exit 0
SH
  cat > "$CASE_DIR/bin/iwctl" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == device && ${2:-} == list ]]; then
  printf '%s\n' "${IWCTL_DEVICE_LIST:-}"
  exit 0
fi
printf 'interactive\n' >> "$LOG_DIR/iwctl"
exit 0
SH
  cat > "$CASE_DIR/bin/lsblk" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *' -J '* ]]; then
  if [[ -n ${LSBLK_JSON:-} ]]; then
    printf '%s\n' "$LSBLK_JSON"
  else
    printf '{"blockdevices":[]}\n'
  fi
else
  printf 'NAME SIZE TYPE FSTYPE MOUNTPOINTS\n'
  printf 'test 100G disk\n'
fi
SH
  cat > "$CASE_DIR/bin/archinstall" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG_DIR/archinstall"
exit "${ARCHINSTALL_EXIT:-0}"
SH
  cat > "$CASE_DIR/helper" <<'PY'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path

log_dir = Path(os.environ['LOG_DIR'])
with (log_dir / 'helper').open('a', encoding='utf-8') as stream:
    stream.write(' '.join(sys.argv[1:]) + '\n')
if os.environ.get('HELPER_FAIL') == '1':
    raise SystemExit(1)
args = sys.argv[1:]
output = Path(args[args.index('--output') + 1])
output.write_text('{"disk_config":{}}\n', encoding='utf-8')
PY
  chmod +x "$CASE_DIR/bin/"*
  export PATH="$CASE_DIR/bin:$ORIGINAL_PATH"
  export CURL_FAIL_COUNT=0
  export IWCTL_DEVICE_LIST=''
  export LSBLK_JSON='{"blockdevices":[]}'
  export HELPER_FAIL=0
  export ARCHINSTALL_EXIT=0
}

cleanup_case() {
  PATH=$ORIGINAL_PATH
  export PATH
  rm -rf "$CASE_DIR"
}

run_launcher() {
  local input=${1:-}
  if [[ -n $input ]]; then
    printf '%s\n' "$input" | "$CASE_DIR/launcher" > "$CASE_DIR/output" 2>&1
  else
    "$CASE_DIR/launcher" > "$CASE_DIR/output" 2>&1
  fi
}

readonly ORIGINAL_PATH=$PATH

new_case
run_launcher
[[ ! -e $LOG_DIR/iwctl ]] || fail 'online startup invoked iwctl'
grep -Fq -- "--config $CASE_DIR/preset.json" "$LOG_DIR/archinstall" || fail 'online startup did not use canonical preset'
grep -Fqi 'create one normal user' "$CASE_DIR/output" || fail 'account guidance missing'
cleanup_case

new_case
export CURL_FAIL_COUNT=5
export IWCTL_DEVICE_LIST=$'Devices\nName Address Powered Adapter Mode\nwlan0 xx on phy0 station'
run_launcher
grep -Fq interactive "$LOG_DIR/iwctl" || fail 'offline startup did not invoke iwctl'
grep -Fq -- "--config $CASE_DIR/preset.json" "$LOG_DIR/archinstall" || fail 'post-Wi-Fi startup did not continue to Archinstall'
cleanup_case

new_case
export CURL_FAIL_COUNT=10
export IWCTL_DEVICE_LIST=''
run_launcher
[[ ! -e $LOG_DIR/archinstall ]] || fail 'offline startup without Wi-Fi device launched Archinstall'
grep -Fq 'archinstall --config' "$CASE_DIR/output" || fail 'offline no-device case did not expose recovery command'
cleanup_case

new_case
export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":false,"tran":"nvme","size":1000000000000,"model":"Internal SSD","mountpoints":[null],"children":[]}]}'
run_launcher 'WIPE /dev/nvme0n1'
grep -Fq -- "--device /dev/nvme0n1 --base-config $CASE_DIR/preset.json --output $CASE_DIR/runtime.json" "$LOG_DIR/helper" || fail 'confirmed internal disk did not invoke helper'
grep -Fq -- "--config $CASE_DIR/runtime.json" "$LOG_DIR/archinstall" || fail 'confirmed internal disk did not use runtime preset'
cleanup_case

new_case
export LSBLK_JSON='{"blockdevices":[{"path":"/dev/sdb","type":"disk","rm":false,"hotplug":false,"tran":"usb","size":1000000000000,"model":"External SSD","mountpoints":[null],"children":[]}]}'
run_launcher
[[ ! -e $LOG_DIR/helper ]] || fail 'USB transport disk was proposed for automation'
grep -Fq -- "--config $CASE_DIR/preset.json" "$LOG_DIR/archinstall" || fail 'USB disk case did not fall back to canonical preset'
cleanup_case

new_case
export LSBLK_JSON='{"blockdevices":[{"path":"/dev/mmcblk0","type":"disk","rm":true,"hotplug":false,"tran":null,"size":64000000000,"model":"Removable","mountpoints":[null],"children":[]}]}'
run_launcher
[[ ! -e $LOG_DIR/helper ]] || fail 'removable disk was proposed for automation'
grep -Fq -- "--config $CASE_DIR/preset.json" "$LOG_DIR/archinstall" || fail 'removable disk case did not fall back to canonical preset'
cleanup_case

new_case
export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":false,"tran":"nvme","size":500000000000,"model":"Live Disk","mountpoints":[null],"children":[{"path":"/dev/nvme0n1p1","type":"part","rm":false,"hotplug":false,"tran":"nvme","size":4000000000,"model":null,"mountpoints":["/run/archiso/bootmnt"]}]}]}'
run_launcher
[[ ! -e $LOG_DIR/helper ]] || fail 'live installer parent disk was proposed for automation'
grep -Fq -- "--config $CASE_DIR/preset.json" "$LOG_DIR/archinstall" || fail 'live installer disk case did not fall back'
cleanup_case

new_case
export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":false,"tran":"nvme","size":500000000000,"model":"SSD 1","mountpoints":[null],"children":[]},{"path":"/dev/nvme1n1","type":"disk","rm":false,"hotplug":false,"tran":"nvme","size":500000000000,"model":"SSD 2","mountpoints":[null],"children":[]}]}'
run_launcher
[[ ! -e $LOG_DIR/helper ]] || fail 'multiple internal disks triggered automation'
grep -Fq -- "--config $CASE_DIR/preset.json" "$LOG_DIR/archinstall" || fail 'multiple disks did not fall back to canonical preset'
cleanup_case

new_case
export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":false,"tran":"nvme","size":500000000000,"model":"SSD","mountpoints":[null],"children":[]}]}'
run_launcher 'no'
[[ ! -e $LOG_DIR/helper ]] || fail 'confirmation mismatch invoked helper'
grep -Fq -- "--config $CASE_DIR/preset.json" "$LOG_DIR/archinstall" || fail 'confirmation mismatch did not fall back'
cleanup_case

new_case
export LSBLK_JSON='{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"hotplug":false,"tran":"nvme","size":500000000000,"model":"SSD","mountpoints":[null],"children":[]}]}'
export HELPER_FAIL=1
run_launcher 'WIPE /dev/nvme0n1'
grep -Fq -- "--config $CASE_DIR/preset.json" "$LOG_DIR/archinstall" || fail 'helper failure did not fall back'
cleanup_case

new_case
export ARCHINSTALL_EXIT=130
run_launcher
grep -Fq 'Archinstall exited with status 130' "$CASE_DIR/output" || fail 'Archinstall cancellation status was not reported'
grep -Fq 'archinstall --config' "$CASE_DIR/output" || fail 'Archinstall cancellation did not expose recovery command'
[[ $(wc -l < "$LOG_DIR/archinstall") -eq 1 ]] || fail 'Archinstall cancellation launched more than once'
export ARCHINSTALL_EXIT=0
run_launcher
[[ $(wc -l < "$LOG_DIR/archinstall") -eq 1 ]] || fail 'one-shot sentinel did not prevent immediate relaunch'
cleanup_case

printf 'ok\n'
