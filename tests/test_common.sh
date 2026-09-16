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
SH
chmod +x "$tmp/bin/runuser"
PATH="$tmp/bin:$PATH"
CHECK_MODE=1
run_as_user_mutation pavel 'user command' printf hello
assert_eq '' "$(cat "$RUNUSER_CALLS")" 'check mode avoids runuser'
CHECK_MODE=0
run_as_user_mutation pavel 'user command' printf hello
assert_eq '-u pavel -- printf hello' "$(cat "$RUNUSER_CALLS")" 'user mutation uses runuser'
