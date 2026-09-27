#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh
source modules/discovery.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
LOG_FILE="$tmp/log"
VERBOSE=0

CALLS=''
AVAHI_ENABLED=0
AVAHI_ACTIVE=0
RESOLVED_ENABLED=0
RESOLVED_ACTIVE=0
RESOLVED_TARGET_ENABLED=0

pacman() {
  CALLS+="pacman:$*"$'\n'
}

systemctl() {
  CALLS+="systemctl:$*"$'\n'

  local rooted=0
  if [[ ${1:-} == --root=/ ]]; then
    rooted=1
    shift
  fi

  local action=${1:-}
  shift || true
  [[ ${1:-} == --quiet ]] && shift
  local unit=${1:-}

  if [[ $unit == systemd-resolved.service ]]; then
    case "$action" in
      is-enabled)
        if (( rooted )); then
          (( RESOLVED_TARGET_ENABLED ))
        else
          (( RESOLVED_ENABLED ))
        fi
        ;;
      is-active)
        (( ! rooted && RESOLVED_ACTIVE ))
        ;;
      *) return 0 ;;
    esac
    return
  fi

  case "$action" in
    is-enabled) (( AVAHI_ENABLED )) ;;
    enable) AVAHI_ENABLED=1 ;;
    is-active) (( AVAHI_ACTIVE )) ;;
    start) AVAHI_ACTIVE=1 ;;
    *) return 0 ;;
  esac
}

reset_fixture() {
  CALLS=''
  AVAHI_ENABLED=0
  AVAHI_ACTIVE=0
  RESOLVED_ENABLED=0
  RESOLVED_ACTIVE=0
  RESOLVED_TARGET_ENABLED=0
  CHECK_MODE=0
  INSTALL_MODE=0
  : > "$LOG_FILE"
}

reset_fixture
configure_discovery
assert_contains "$CALLS" 'pacman:-S --needed --noconfirm -- avahi gvfs-dnssd' 'normal mode installs discovery packages'
assert_contains "$CALLS" 'systemctl:enable avahi-daemon.service' 'normal mode enables Avahi'
assert_contains "$CALLS" 'systemctl:start avahi-daemon.service' 'normal mode starts Avahi'
assert_eq 1 "$AVAHI_ENABLED" 'normal mode leaves Avahi enabled'
assert_eq 1 "$AVAHI_ACTIVE" 'normal mode leaves Avahi active'

CALLS=''
configure_discovery
if [[ $CALLS == *'systemctl:enable avahi-daemon.service'* || $CALLS == *'systemctl:start avahi-daemon.service'* ]]; then
  printf 'FAIL: normal-mode rerun repeated Avahi service mutations\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi

reset_fixture
RESOLVED_ENABLED=1
if configure_discovery 2>"$tmp/resolved-enabled.err"; then
  printf 'FAIL: enabled systemd-resolved accepted alongside Avahi\n' >&2
  exit 1
fi
assert_file_contains "$tmp/resolved-enabled.err" 'refusing to enable Avahi because get-arch does not infer resolved or per-connection mDNS ownership'
if [[ $CALLS == *'pacman:'* || $CALLS == *'systemctl:enable avahi-daemon.service'* || $CALLS == *'systemctl:start avahi-daemon.service'* ]]; then
  printf 'FAIL: resolver conflict mutated discovery state\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi

reset_fixture
RESOLVED_ACTIVE=1
if configure_discovery 2>"$tmp/resolved-active.err"; then
  printf 'FAIL: active systemd-resolved accepted alongside Avahi\n' >&2
  exit 1
fi
assert_file_contains "$tmp/resolved-active.err" 'systemd-resolved.service is active or enabled'

reset_fixture
INSTALL_MODE=1
RESOLVED_ACTIVE=1
configure_discovery
assert_contains "$CALLS" 'pacman:-S --needed --noconfirm -- avahi gvfs-dnssd' 'install mode ignores live-only systemd-resolved activity'
assert_contains "$CALLS" 'systemctl:--root=/ enable avahi-daemon.service' 'install mode enables Avahi in the target'
if [[ $CALLS == *'systemctl:is-active --quiet systemd-resolved.service'* || $CALLS == *'systemctl:enable avahi-daemon.service'* || $CALLS == *'systemctl:start avahi-daemon.service'* ]]; then
  printf 'FAIL: install mode touched the live discovery stack\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi
assert_eq 1 "$AVAHI_ENABLED" 'install mode leaves target Avahi enabled'
assert_eq 0 "$AVAHI_ACTIVE" 'install mode does not start Avahi inside the installer'

reset_fixture
INSTALL_MODE=1
RESOLVED_TARGET_ENABLED=1
if configure_discovery 2>"$tmp/resolved-target.err"; then
  printf 'FAIL: target-enabled systemd-resolved accepted alongside Avahi\n' >&2
  exit 1
fi
assert_file_contains "$tmp/resolved-target.err" 'systemd-resolved.service is enabled in the installed system'
if [[ $CALLS == *'pacman:'* || $CALLS == *'systemctl:--root=/ enable avahi-daemon.service'* ]]; then
  printf 'FAIL: target resolver conflict mutated discovery state\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi

reset_fixture
CHECK_MODE=1
configure_discovery > "$tmp/check-output"
check_output=$(<"$tmp/check-output")
assert_contains "$check_output" '[CHECK] Install packages: avahi gvfs-dnssd:' 'check mode reports discovery packages'
assert_contains "$check_output" '[CHECK] Enable avahi-daemon.service:' 'check mode reports Avahi enablement'
assert_contains "$check_output" '[CHECK] Start avahi-daemon.service:' 'check mode reports Avahi startup'
if [[ $CALLS == *'pacman:'* || $CALLS == *'systemctl:enable '* || $CALLS == *'systemctl:start '* ]]; then
  printf 'FAIL: check mode mutated discovery state\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi
assert_eq 0 "$AVAHI_ENABLED" 'check mode leaves Avahi disabled'
assert_eq 0 "$AVAHI_ACTIVE" 'check mode leaves Avahi inactive'

reset_fixture
CHECK_MODE=1
RESOLVED_ENABLED=1
if configure_discovery >"$tmp/check-conflict.out" 2>"$tmp/check-conflict.err"; then
  printf 'FAIL: check mode accepted a systemd-resolved conflict\n' >&2
  exit 1
fi
assert_file_contains "$tmp/check-conflict.err" 'refusing to enable Avahi because get-arch does not infer resolved or per-connection mDNS ownership'
if [[ $CALLS == *'pacman:'* || $CALLS == *'systemctl:enable '* || $CALLS == *'systemctl:start '* ]]; then
  printf 'FAIL: conflicting check mode mutated discovery state\n' >&2
  printf '%s' "$CALLS" >&2
  exit 1
fi
