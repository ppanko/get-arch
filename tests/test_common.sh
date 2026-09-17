#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
GET_ARCH_ROOT=$tmp
assert_eq "$tmp/etc/hostname" "$(system_path /etc/hostname)" 'system_path honors test root'

marker="$tmp/mutated"
CHECK_MODE=1
run_mutation 'touch marker' touch "$marker"
[[ ! -e "$marker" ]] || { echo 'FAIL: check mode mutated system' >&2; exit 1; }

CHECK_MODE=0
LOG_FILE="$tmp/log"
VERBOSE=0
run_mutation 'touch marker' touch "$marker"
[[ -e "$marker" ]] || { echo 'FAIL: normal mode did not execute mutation' >&2; exit 1; }

mkdir -p "$tmp/bin"
export RUNUSER_CALLS="$tmp/runuser-calls"
: > "$RUNUSER_CALLS"
cat > "$tmp/bin/runuser" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUNUSER_CALLS"
printf 'interactive user output\n'
SH
chmod +x "$tmp/bin/runuser"
PATH="$tmp/bin:$PATH"
CHECK_MODE=1
run_as_user_mutation pavel 'user command' printf hello
assert_eq '' "$(cat "$RUNUSER_CALLS")" 'check mode avoids runuser'
CHECK_MODE=0
LOG_FILE="$tmp/user-log"
: > "$LOG_FILE"
output=$(run_as_user_mutation pavel 'user command' printf hello 2>&1)
assert_eq '--pty -u pavel -- printf hello' "$(cat "$RUNUSER_CALLS")" 'user mutation isolates command in a pseudo-terminal'
assert_contains "$output" 'interactive user output' 'user-scoped command output remains visible'
assert_file_contains "$LOG_FILE" 'interactive user output'

export SYSTEMCTL_CALLS="$tmp/systemctl-calls"
systemctl() {
  printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
  case " $* " in
    *' is-enabled '*) return 1 ;;
    *' is-active '*) return 1 ;;
  esac
  return 0
}

: > "$SYSTEMCTL_CALLS"
INSTALL_MODE=1
ensure_service_enabled sshd.service
ensure_service_started sshd.service
systemctl_calls=$(cat "$SYSTEMCTL_CALLS")
assert_eq $'--root=/ is-enabled --quiet sshd.service\n--root=/ enable sshd.service' "$systemctl_calls" 'install mode enables against target root only'
[[ $systemctl_calls != *'is-active'* && $systemctl_calls != *' start '* ]] || {
  echo 'FAIL: install mode inspected or started a live service' >&2
  exit 1
}

: > "$SYSTEMCTL_CALLS"
INSTALL_MODE=0
ensure_service_enabled sshd.service
ensure_service_started sshd.service
systemctl_calls=$(cat "$SYSTEMCTL_CALLS")
assert_eq $'is-enabled --quiet sshd.service\nenable sshd.service\nis-active --quiet sshd.service\nstart sshd.service' "$systemctl_calls" 'normal mode retains enable-and-start semantics'
