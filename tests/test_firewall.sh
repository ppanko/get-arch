#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh
source modules/firewall.sh
source modules/ssh.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

export FIREWALL_CALLS="$tmp/calls"
export FIREWALL_RULES="$tmp/rules"
export FIREWALL_POLICIES="$tmp/policies"
export SYSTEMCTL_ENABLED="$tmp/enabled"
export SYSTEMCTL_ACTIVE="$tmp/active"
export UFW_CONFIG="$tmp/root/etc/ufw/ufw.conf"
export UFW_DEFAULTS="$tmp/root/etc/default/ufw"
export UFW_RUNTIME="$tmp/runtime"

cat > "$tmp/bin/pacman" <<'PACMAN'
#!/usr/bin/env bash
printf 'pacman:%s\n' "$*" >> "$FIREWALL_CALLS"
PACMAN

cat > "$tmp/bin/ufw" <<'UFW'
#!/usr/bin/env bash
set -euo pipefail
printf 'ufw:%s\n' "$*" >> "$FIREWALL_CALLS"
[[ ${1:-} == --force ]] && shift
case ${1:-} in
  status)
    if grep -Fxq active "$UFW_RUNTIME" 2>/dev/null; then
      printf 'Status: active\n'
    else
      printf 'Status: inactive\n'
    fi
    ;;
  allow)
    rule="allow:${2:-}"
    grep -Fxq "$rule" "$FIREWALL_RULES" 2>/dev/null || printf '%s\n' "$rule" >> "$FIREWALL_RULES"
    ;;
  default)
    direction=${3:-}
    grep -Ev "^${direction}:" "$FIREWALL_POLICIES" 2>/dev/null > "$FIREWALL_POLICIES.tmp" || true
    printf '%s:%s\n' "$direction" "${2:-}" >> "$FIREWALL_POLICIES.tmp"
    mv "$FIREWALL_POLICIES.tmp" "$FIREWALL_POLICIES"
    case "$direction:${2:-}" in
      incoming:deny) sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' "$UFW_DEFAULTS" ;;
      outgoing:allow) sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' "$UFW_DEFAULTS" ;;
    esac
    ;;
  enable)
    sed -i 's/^ENABLED=.*/ENABLED=yes/' "$UFW_CONFIG"
    printf 'active\n' > "$UFW_RUNTIME"
    ;;
  reset|delete|disable|reload)
    printf 'FAIL: destructive UFW command: %s\n' "$*" >&2
    exit 97
    ;;
esac
UFW

cat > "$tmp/bin/unshare" <<'UNSHARE'
#!/usr/bin/env bash
set -euo pipefail
printf 'unshare:%s\n' "$*" >> "$FIREWALL_CALLS"
[[ ${1:-} == --net ]] && shift
[[ ${1:-} == -- ]] && shift
"$@"
UNSHARE

cat > "$tmp/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl:%s\n' "$*" >> "$FIREWALL_CALLS"
if [[ ${1:-} == --root=/ ]]; then shift; fi
action=${1:-}
shift || true
[[ ${1:-} == --quiet ]] && shift
unit=${1:-}
case $action in
  is-enabled) grep -Fxq "$unit" "$SYSTEMCTL_ENABLED" 2>/dev/null ;;
  is-active) grep -Fxq "$unit" "$SYSTEMCTL_ACTIVE" 2>/dev/null ;;
  enable) grep -Fxq "$unit" "$SYSTEMCTL_ENABLED" 2>/dev/null || printf '%s\n' "$unit" >> "$SYSTEMCTL_ENABLED" ;;
  start) grep -Fxq "$unit" "$SYSTEMCTL_ACTIVE" 2>/dev/null || printf '%s\n' "$unit" >> "$SYSTEMCTL_ACTIVE" ;;
esac
SYSTEMCTL

chmod +x "$tmp/bin/pacman" "$tmp/bin/ufw" "$tmp/bin/unshare" "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH"

cat > "$tmp/detect-ancestor-ssh" <<'ANCESTOR'
#!/usr/bin/env bash
source modules/firewall.sh
unset SSH_CONNECTION
detect_active_ssh_connection
ANCESTOR
chmod +x "$tmp/detect-ancestor-ssh"
ancestor_connection=$(
  SSH_CONNECTION='198.51.100.10 51000 192.0.2.10 22022' \
    bash -c 'env -u SSH_CONNECTION bash "$1" & wait' _ "$tmp/detect-ancestor-ssh"
)
assert_eq '198.51.100.10 51000 192.0.2.10 22022' "$ancestor_connection" 'active SSH metadata survives sudo-style environment filtering'

reset_fixture() {
  rm -rf "$tmp/root"
  mkdir -p "$tmp/root/etc/default" "$tmp/root/etc/ufw"
  printf 'ENABLED=no\n' > "$tmp/root/etc/ufw/ufw.conf"
  printf 'DEFAULT_INPUT_POLICY="ACCEPT"\nDEFAULT_OUTPUT_POLICY="DROP"\n' > "$tmp/root/etc/default/ufw"
  : > "$FIREWALL_CALLS"
  : > "$FIREWALL_RULES"
  : > "$FIREWALL_POLICIES"
  : > "$SYSTEMCTL_ENABLED"
  : > "$SYSTEMCTL_ACTIVE"
  printf 'inactive\n' > "$UFW_RUNTIME"
  GET_ARCH_ROOT="$tmp/root"
  LOG_FILE="$tmp/log"
  : > "$LOG_FILE"
  CHECK_MODE=0
  INSTALL_MODE=0
  SSH_CONNECTION='198.51.100.10 51000 192.0.2.10 22'
}

assert_before() {
  local first=$1 second=$2 message=$3 first_line second_line
  first_line=$(grep -nFx -- "$first" "$FIREWALL_CALLS" | head -n1 | cut -d: -f1)
  second_line=$(grep -nFx -- "$second" "$FIREWALL_CALLS" | head -n1 | cut -d: -f1)
  [[ -n $first_line && -n $second_line && $first_line -lt $second_line ]] || {
    printf 'FAIL: %s\n' "$message" >&2
    cat "$FIREWALL_CALLS" >&2
    exit 1
  }
}

reset_fixture
configure_firewall
configure_ssh
assert_before 'ufw:allow 22/tcp' 'ufw:default deny incoming' 'SSH is allowed before the incoming default is enforced'
assert_before 'ufw:allow 22/tcp' 'ufw:--force enable' 'SSH is allowed before UFW is enabled'
assert_before 'ufw:--force enable' 'systemctl:start sshd.service' 'firewall activation precedes SSH service activation'
if grep -Fq 'systemctl:start ufw.service' "$FIREWALL_CALLS"; then
  printf 'FAIL: fresh activation loaded UFW twice\n' >&2
  cat "$FIREWALL_CALLS" >&2
  exit 1
fi
assert_file_contains "$FIREWALL_POLICIES" 'incoming:deny'
assert_file_contains "$FIREWALL_POLICIES" 'outgoing:allow'
assert_file_contains "$FIREWALL_RULES" 'allow:22/tcp'
assert_file_contains "$SYSTEMCTL_ENABLED" 'ufw.service'
assert_file_contains "$SYSTEMCTL_ENABLED" 'sshd.service'
assert_file_contains "$SYSTEMCTL_ACTIVE" 'sshd.service'
assert_file_contains "$tmp/root/etc/ufw/ufw.conf" 'ENABLED=yes'

printf 'allow:8443/tcp\n' >> "$FIREWALL_RULES"
: > "$FIREWALL_CALLS"
configure_firewall
configure_ssh
assert_file_contains "$FIREWALL_RULES" 'allow:8443/tcp'
assert_eq 1 "$(grep -Fxc 'allow:22/tcp' "$FIREWALL_RULES")" 'rerun does not duplicate the SSH rule'
assert_file_contains "$UFW_RUNTIME" 'active'
if grep -Eq '^ufw:(--force enable|reset|delete|disable|reload)|^systemctl:(enable|start)' "$FIREWALL_CALLS"; then
  printf 'FAIL: rerun destructively reconfigured an active firewall\n' >&2
  cat "$FIREWALL_CALLS" >&2
  exit 1
fi
if grep -Fq 'ufw:default ' "$FIREWALL_CALLS"; then
  printf 'FAIL: rerun reapplied an unchanged default policy\n' >&2
  cat "$FIREWALL_CALLS" >&2
  exit 1
fi

reset_fixture
printf 'ENABLED=yes\n' > "$UFW_CONFIG"
printf 'DEFAULT_INPUT_POLICY="DROP"\nDEFAULT_OUTPUT_POLICY="ACCEPT"\n' > "$UFW_DEFAULTS"
printf 'allow:8443/tcp\n' >> "$FIREWALL_RULES"
configure_firewall
assert_file_contains "$FIREWALL_RULES" 'allow:8443/tcp'
assert_before 'ufw:allow 22/tcp' 'ufw:--force enable' 'runtime-inactive recovery protects SSH before activating UFW'
assert_eq 1 "$(grep -Fxc 'ufw:--force enable' "$FIREWALL_CALLS")" 'runtime-inactive recovery activates UFW exactly once'
assert_file_contains "$UFW_RUNTIME" 'active'

reset_fixture
SSH_CONNECTION='198.51.100.10 51000 192.0.2.10 22022'
configure_firewall
assert_before 'ufw:allow 22022/tcp' 'ufw:--force enable' 'active SSH port is allowed before UFW is enabled'
assert_file_contains "$FIREWALL_RULES" 'allow:22022/tcp'
if grep -Eq '^ufw:(reset|delete|disable|reload)|^systemctl:stop' "$FIREWALL_CALLS"; then
  printf 'FAIL: active SSH handling included a teardown operation\n' >&2
  exit 1
fi

reset_fixture
SSH_CONNECTION='malformed'
if configure_firewall; then
  printf 'FAIL: malformed active SSH metadata was accepted\n' >&2
  exit 1
fi
if grep -Fq 'ufw:--force enable' "$FIREWALL_CALLS"; then
  printf 'FAIL: firewall activated without validating the active SSH port\n' >&2
  exit 1
fi

reset_fixture
INSTALL_MODE=1
SSH_CONNECTION='198.51.100.10 51000 192.0.2.10 22022'
configure_firewall
configure_ssh
assert_contains "$(cat "$FIREWALL_CALLS")" 'unshare:--net -- ufw allow 22/tcp' 'install mode isolates UFW from the live ISO network namespace'
assert_eq "$(grep -c '^ufw:' "$FIREWALL_CALLS")" "$(grep -c '^unshare:--net -- ufw ' "$FIREWALL_CALLS")" 'install mode isolates every UFW command'
assert_contains "$(cat "$FIREWALL_CALLS")" 'systemctl:--root=/ enable ufw.service' 'install mode enables target UFW service'
assert_contains "$(cat "$FIREWALL_CALLS")" 'systemctl:--root=/ enable sshd.service' 'install mode enables target SSH service'
assert_file_contains "$FIREWALL_RULES" 'allow:22/tcp'
assert_file_contains "$FIREWALL_POLICIES" 'incoming:deny'
assert_file_contains "$FIREWALL_POLICIES" 'outgoing:allow'
assert_file_contains "$tmp/root/etc/ufw/ufw.conf" 'ENABLED=yes'
if grep -Eq '^systemctl:(is-active|start)|22022/tcp' "$FIREWALL_CALLS"; then
  printf 'FAIL: install mode touched a live service or copied the installer SSH port\n' >&2
  cat "$FIREWALL_CALLS" >&2
  exit 1
fi

reset_fixture
printf 'allow:8443/tcp\n' >> "$FIREWALL_RULES"
CHECK_MODE=1
check_output=$(configure_firewall; configure_ssh)
assert_contains "$check_output" '[CHECK] Allow SSH through UFW:' 'check mode reports the SSH firewall rule'
assert_contains "$check_output" '[CHECK] Set UFW default incoming policy:' 'check mode reports the incoming policy'
assert_contains "$check_output" '[CHECK] Set UFW default outgoing policy:' 'check mode reports the outgoing policy'
assert_contains "$check_output" '[CHECK] Enable UFW:' 'check mode reports firewall activation policy'
assert_contains "$check_output" '[CHECK] Enable ufw.service:' 'check mode reports boot-time firewall enablement'
assert_eq 'ENABLED=no' "$(cat "$tmp/root/etc/ufw/ufw.conf")" 'check mode leaves UFW configuration unchanged'
assert_eq 'allow:8443/tcp' "$(cat "$FIREWALL_RULES")" 'check mode preserves existing rules without mutation'
if grep -Eq '^(pacman|ufw|unshare):|^systemctl:(enable|start)' "$FIREWALL_CALLS"; then
  printf 'FAIL: check mode executed a mutation\n' >&2
  cat "$FIREWALL_CALLS" >&2
  exit 1
fi

if rg -n 'ufw[[:space:]].*(reset|delete)|ufw[[:space:]]+(reset|delete)' modules/firewall.sh >/dev/null; then
  printf 'FAIL: firewall module contains a destructive UFW operation\n' >&2
  exit 1
fi
