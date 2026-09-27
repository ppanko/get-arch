#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh
source modules/bluetooth.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
LOG_FILE="$tmp/log"
VERBOSE=0

CALLS=''
BT_ENABLED=0
BT_ACTIVE=0
BT_HARDWARE=1

pacman() {
  CALLS+="pacman:$*"$'\n'
}

systemctl() {
  CALLS+="systemctl:$*"$'\n'
  if [[ ${1:-} == --root=/ ]]; then
    shift
  fi

  local action=${1:-}
  shift || true
  [[ ${1:-} == --quiet ]] && shift

  case "$action" in
    is-enabled) (( BT_ENABLED )) ;;
    enable) BT_ENABLED=1 ;;
    is-active) (( BT_ACTIVE )) ;;
    start)
      if (( BT_HARDWARE )); then
        BT_ACTIVE=1
      fi
      return 0
      ;;
    *) return 0 ;;
  esac
}

reset_fixture() {
  CALLS=''
  BT_ENABLED=0
  BT_ACTIVE=0
  BT_HARDWARE=1
  CHECK_MODE=0
  INSTALL_MODE=0
  : > "$LOG_FILE"
}

reset_fixture
configure_bluetooth
assert_contains "$CALLS" 'pacman:-S --needed --noconfirm -- bluez bluez-utils' 'normal mode installs the Bluetooth package set'
assert_contains "$CALLS" 'systemctl:enable bluetooth.service' 'normal mode enables Bluetooth'
assert_contains "$CALLS" 'systemctl:start bluetooth.service' 'normal mode starts Bluetooth'
assert_eq 1 "$BT_ENABLED" 'normal mode leaves Bluetooth enabled'
assert_eq 1 "$BT_ACTIVE" 'normal mode leaves Bluetooth active when hardware is present'

CALLS=''
configure_bluetooth
if [[ $CALLS == *'systemctl:enable bluetooth.service'* || $CALLS == *'systemctl:start bluetooth.service'* ]]; then
  printf 'FAIL: normal-mode rerun repeated Bluetooth service mutations\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi

reset_fixture
BT_HARDWARE=0
configure_bluetooth
assert_eq 1 "$BT_ENABLED" 'hardwareless machine still enables the Bluetooth capability'
assert_eq 0 "$BT_ACTIVE" 'hardwareless machine may leave Bluetooth inactive'
assert_contains "$CALLS" 'systemctl:start bluetooth.service' 'hardwareless machine may request a condition-skipped start'

reset_fixture
INSTALL_MODE=1
configure_bluetooth
assert_contains "$CALLS" 'pacman:-S --needed --noconfirm -- bluez bluez-utils' 'install mode installs the Bluetooth package set'
assert_contains "$CALLS" 'systemctl:--root=/ enable bluetooth.service' 'install mode enables Bluetooth in the target'
if [[ $CALLS == *'is-active'* || $CALLS == *'systemctl:enable bluetooth.service'* || $CALLS == *'systemctl:start bluetooth.service'* ]]; then
  printf 'FAIL: install mode touched the live Bluetooth service\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi
assert_eq 1 "$BT_ENABLED" 'install mode leaves target Bluetooth enabled'
assert_eq 0 "$BT_ACTIVE" 'install mode does not start Bluetooth inside the installer'

reset_fixture
CHECK_MODE=1
configure_bluetooth > "$tmp/check-output"
check_output=$(<"$tmp/check-output")
assert_contains "$check_output" '[CHECK] Install packages: bluez bluez-utils:' 'check mode reports Bluetooth packages'
assert_contains "$check_output" '[CHECK] Enable bluetooth.service:' 'check mode reports Bluetooth enablement'
assert_contains "$check_output" '[CHECK] Start bluetooth.service:' 'check mode reports Bluetooth startup'
if [[ $CALLS == *'pacman:'* || $CALLS == *'systemctl:enable '* || $CALLS == *'systemctl:start '* ]]; then
  printf 'FAIL: check mode mutated Bluetooth state\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi
assert_eq 0 "$BT_ENABLED" 'check mode leaves Bluetooth disabled'
assert_eq 0 "$BT_ACTIVE" 'check mode leaves Bluetooth inactive'
