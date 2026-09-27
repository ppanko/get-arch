#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh
source modules/printing.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
LOG_FILE="$tmp/log"
VERBOSE=0

CALLS=''
CUPS_SOCKET_ENABLED=0
CUPS_SOCKET_ACTIVE=0

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
    is-enabled) (( CUPS_SOCKET_ENABLED )) ;;
    enable) CUPS_SOCKET_ENABLED=1 ;;
    is-active) (( CUPS_SOCKET_ACTIVE )) ;;
    start) CUPS_SOCKET_ACTIVE=1 ;;
    *) return 0 ;;
  esac
}

reset_fixture() {
  CALLS=''
  CUPS_SOCKET_ENABLED=0
  CUPS_SOCKET_ACTIVE=0
  CHECK_MODE=0
  INSTALL_MODE=0
  : > "$LOG_FILE"
}

reset_fixture
configure_printing
assert_contains "$CALLS" 'pacman:-S --needed --noconfirm -- cups' 'normal mode installs CUPS'
assert_contains "$CALLS" 'systemctl:enable cups.socket' 'normal mode enables CUPS socket activation'
assert_contains "$CALLS" 'systemctl:start cups.socket' 'normal mode starts the CUPS socket'
assert_eq 1 "$CUPS_SOCKET_ENABLED" 'normal mode leaves the CUPS socket enabled'
assert_eq 1 "$CUPS_SOCKET_ACTIVE" 'normal mode leaves the CUPS socket active'

CALLS=''
configure_printing
if [[ $CALLS == *'systemctl:enable cups.socket'* || $CALLS == *'systemctl:start cups.socket'* ]]; then
  printf 'FAIL: normal-mode rerun repeated CUPS socket mutations\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi

reset_fixture
INSTALL_MODE=1
configure_printing
assert_contains "$CALLS" 'pacman:-S --needed --noconfirm -- cups' 'install mode installs CUPS'
assert_contains "$CALLS" 'systemctl:--root=/ enable cups.socket' 'install mode enables CUPS socket activation in the target'
if [[ $CALLS == *'is-active'* || $CALLS == *'systemctl:enable cups.socket'* || $CALLS == *'systemctl:start cups.socket'* ]]; then
  printf 'FAIL: install mode touched the live CUPS socket\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi
assert_eq 1 "$CUPS_SOCKET_ENABLED" 'install mode leaves target CUPS socket enabled'
assert_eq 0 "$CUPS_SOCKET_ACTIVE" 'install mode does not start CUPS inside the installer'

reset_fixture
CHECK_MODE=1
configure_printing > "$tmp/check-output"
check_output=$(<"$tmp/check-output")
assert_contains "$check_output" '[CHECK] Install packages: cups:' 'check mode reports CUPS installation'
assert_contains "$check_output" '[CHECK] Enable cups.socket:' 'check mode reports CUPS socket enablement'
assert_contains "$check_output" '[CHECK] Start cups.socket:' 'check mode reports CUPS socket activation'
if [[ $CALLS == *'pacman:'* || $CALLS == *'systemctl:enable '* || $CALLS == *'systemctl:start '* ]]; then
  printf 'FAIL: check mode mutated printing state\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi
assert_eq 0 "$CUPS_SOCKET_ENABLED" 'check mode leaves CUPS socket disabled'
assert_eq 0 "$CUPS_SOCKET_ACTIVE" 'check mode leaves CUPS socket inactive'
