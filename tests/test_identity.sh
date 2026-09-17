#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh
source modules/identity.sh

validate_username pavel
if validate_username 'Pavel Smith'; then echo 'FAIL: invalid username accepted' >&2; exit 1; fi
if validate_username '-root'; then echo 'FAIL: invalid username accepted' >&2; exit 1; fi
validate_hostname arch-laptop
if validate_hostname '-arch'; then echo 'FAIL: invalid hostname accepted' >&2; exit 1; fi
if validate_hostname 'arch_1'; then echo 'FAIL: invalid hostname accepted' >&2; exit 1; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/etc/sudoers.d"
export GET_ARCH_ROOT="$tmp/root"
mkdir -p "$GET_ARCH_ROOT/etc/sudoers.d"
export CALLS="$tmp/calls"
: > "$CALLS"

cat > "$tmp/bin/pacman" <<'SH'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >> "$CALLS"
SH
cat > "$tmp/bin/id" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then exit 1; fi
exit 1
SH
cat > "$tmp/bin/useradd" <<'SH'
#!/usr/bin/env bash
printf 'useradd %s\n' "$*" >> "$CALLS"
SH
cat > "$tmp/bin/usermod" <<'SH'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >> "$CALLS"
SH
cat > "$tmp/bin/visudo" <<'SH'
#!/usr/bin/env bash
printf 'visudo %s\n' "$*" >> "$CALLS"
exit 0
SH
cat > "$tmp/bin/install" <<'SH'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >> "$CALLS"
src=${@: -2:1}; dest=${@: -1}
mkdir -p "$(dirname "$dest")"
cp "$src" "$dest"
chmod 0440 "$dest"
SH
cat > "$tmp/bin/hostnamectl" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == --static ]]; then printf 'oldhost\n'; else printf 'hostnamectl %s\n' "$*" >> "$CALLS"; fi
SH
cat > "$tmp/bin/passwd" <<'SH'
#!/usr/bin/env bash
printf 'passwd %s\n' "$*" >> "$CALLS"
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
CHECK_MODE=0
VERBOSE=0
LOG_FILE="$tmp/log"
USERNAME=pavel
HOSTNAME_VALUE=arch-laptop
configure_identity
calls=$(cat "$CALLS")
assert_contains "$calls" 'pacman -S --needed --noconfirm -- sudo' 'sudo package installed'
assert_contains "$calls" 'useradd -m -G wheel -s /bin/bash pavel' 'user created with wheel'
[[ "$calls" != *'usermod '* ]] || { echo 'FAIL: new wheel user should not need usermod' >&2; exit 1; }
assert_contains "$calls" 'visudo -cf' 'sudoers validated'
assert_contains "$calls" 'hostnamectl set-hostname arch-laptop' 'hostname updated'
assert_contains "$calls" 'passwd pavel' 'new user password requested'
assert_file_contains "$GET_ARCH_ROOT/etc/sudoers.d/10-wheel" '%wheel ALL=(ALL:ALL) ALL'
mode=$(stat -c '%a' "$GET_ARCH_ROOT/etc/sudoers.d/10-wheel")
assert_eq 440 "$mode" 'sudoers mode'

: > "$CALLS"
cat > "$tmp/bin/id" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then printf '1000\n'; exit 0; fi
if [[ ${1:-} == -nG ]]; then printf 'users wheel\n'; exit 0; fi
exit 1
SH
cat > "$tmp/bin/hostnamectl" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == --static ]]; then printf 'arch-laptop\n'; else printf 'hostnamectl %s\n' "$*" >> "$CALLS"; fi
SH
chmod +x "$tmp/bin/id" "$tmp/bin/hostnamectl"
configure_identity
calls=$(cat "$CALLS")
[[ "$calls" != *'useradd '* ]] || { echo 'FAIL: existing user recreated' >&2; exit 1; }
[[ "$calls" != *'usermod '* ]] || { echo 'FAIL: wheel membership changed unnecessarily' >&2; exit 1; }
[[ "$calls" != *'hostnamectl set-hostname'* ]] || { echo 'FAIL: unchanged hostname reset' >&2; exit 1; }
[[ "$calls" != *'passwd '* ]] || { echo 'FAIL: existing user password prompted' >&2; exit 1; }
