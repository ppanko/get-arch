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

# Existing system accounts must never be accepted as the workstation user.
(
  id() {
    [[ ${1:-} == -u ]] || return 1
    case ${2:-} in
      pavel) printf '1000\n' ;;
      root) printf '0\n' ;;
      nobody) printf '65534\n' ;;
      *) return 1 ;;
    esac
  }
  validate_target_user pavel || { echo 'FAIL: normal existing user rejected' >&2; exit 1; }
  validate_target_user newuser || { echo 'FAIL: new normal username rejected' >&2; exit 1; }
  if validate_target_user root; then echo 'FAIL: root accepted as workstation user' >&2; exit 1; fi
  if validate_target_user nobody; then echo 'FAIL: system account accepted as workstation user' >&2; exit 1; fi
)

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
if [[ ${1:-} == -S ]]; then printf '%s P 2026-09-17 0 99999 7 -1\n' "$2"; exit 0; fi
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
[[ "$calls" != *'passwd pavel'* ]] || { echo 'FAIL: usable existing password prompted' >&2; exit 1; }

# A partially completed prior run must recover by setting a locked user's password.
cat > "$tmp/bin/passwd" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == -S ]]; then printf '%s L 2026-09-17 0 99999 7 -1\n' "$2"; exit 0; fi
printf 'passwd %s\n' "$*" >> "$CALLS"
SH
chmod +x "$tmp/bin/passwd"
: > "$CALLS"
configure_identity
calls=$(cat "$CALLS")
assert_contains "$calls" 'passwd pavel' 'locked existing user password retried on rerun'

# Check mode must work on a minimal system where sudo/visudo is not installed yet.
rm -f "$GET_ARCH_ROOT/etc/sudoers.d/10-wheel"
mkdir -p "$tmp/no-visudo-bin"
ln -s "$(command -v mktemp)" "$tmp/no-visudo-bin/mktemp"
ln -s "$(command -v rm)" "$tmp/no-visudo-bin/rm"
cat > "$tmp/no-visudo-bin/id" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$tmp/no-visudo-bin/hostnamectl" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == --static ]]; then printf 'oldhost\n'; else exit 99; fi
SH
chmod +x "$tmp/no-visudo-bin/id" "$tmp/no-visudo-bin/hostnamectl"
: > "$CALLS"
CHECK_MODE=1
output=$(PATH="$tmp/no-visudo-bin" configure_identity 2>&1)
assert_contains "$output" 'sudo is not installed yet' 'check mode defers sudoers validation until sudo is installed'
assert_eq '' "$(cat "$CALLS")" 'check mode without visudo makes no mutations'

# Install mode discovers only existing normal login users and reads the
# hostname without changing either identity.
install_root="$tmp/install-root"
mkdir -p "$install_root/etc/sudoers.d"
cat > "$install_root/etc/login.defs" <<'EOF'
UID_MIN 1000
UID_MAX 60000
EOF
cat > "$install_root/etc/hostname" <<'EOF'
installed-host
EOF
cat > "$install_root/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:2:2:daemon:/sbin:/usr/bin/nologin
pavel:x:1000:1000:Pavel:/home/pavel:/bin/bash
EOF

GET_ARCH_ROOT="$install_root"
INSTALL_MODE=1
USERNAME=''
HOSTNAME_VALUE=''
select_installed_identity
assert_eq pavel "$USERNAME" 'single normal login user is selected'
assert_eq installed-host "$HOSTNAME_VALUE" 'installed hostname is read'

cat >> "$install_root/etc/passwd" <<'EOF'
alice:x:1001:1001:Alice:/home/alice:/bin/zsh
EOF
USERNAME=alice
select_installed_identity
assert_eq alice "$USERNAME" 'explicit existing normal user is selected'

USERNAME=''
set +e
output=$(select_installed_identity 2>&1); status=$?
set -e
assert_eq 1 "$status" 'multiple-user autodetection status'
assert_contains "$output" 'Multiple normal login users found' 'multiple users require explicit selection'
assert_contains "$output" '--user USER' 'multiple-user guidance'

USERNAME=missing
set +e
output=$(select_installed_identity 2>&1); status=$?
set -e
assert_eq 1 "$status" 'missing explicit user status'
assert_contains "$output" "User 'missing' is not an existing normal login user" 'missing explicit user rejected'

cat > "$install_root/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:2:2:daemon:/sbin:/usr/bin/nologin
EOF
USERNAME=''
set +e
output=$(select_installed_identity 2>&1); status=$?
set -e
assert_eq 1 "$status" 'zero-user autodetection status'
assert_contains "$output" 'No normal login user found' 'zero-user failure is actionable'

cat > "$install_root/etc/hostname" <<'EOF'
-invalid-host
EOF
set +e
output=$(select_installed_identity 2>&1); status=$?
set -e
assert_eq 1 "$status" 'invalid installed hostname status'
assert_contains "$output" 'installed hostname is invalid' 'invalid installed hostname rejected'

# Install-mode identity configuration may add wheel membership and the normal
# sudo policy, but must not invoke any user, password, or hostname mutation.
cat > "$install_root/etc/hostname" <<'EOF'
installed-host
EOF
cat > "$install_root/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
pavel:x:1000:1000:Pavel:/home/pavel:/bin/bash
EOF
cat > "$tmp/bin/id" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == -u && ${2:-} == pavel ]]; then printf '1000\n'; exit 0; fi
if [[ ${1:-} == -nG && ${2:-} == pavel ]]; then printf 'users\n'; exit 0; fi
exit 1
SH
cat > "$tmp/bin/passwd" <<'SH'
#!/usr/bin/env bash
printf 'passwd %s\n' "$*" >> "$CALLS"
exit 0
SH
cat > "$tmp/bin/hostnamectl" <<'SH'
#!/usr/bin/env bash
printf 'hostnamectl %s\n' "$*" >> "$CALLS"
exit 0
SH
chmod +x "$tmp/bin/id" "$tmp/bin/passwd" "$tmp/bin/hostnamectl"
CHECK_MODE=0
LOG_FILE="$tmp/install-log"
USERNAME=pavel
HOSTNAME_VALUE=installed-host
: > "$CALLS"
rm -f "$install_root/etc/sudoers.d/10-wheel"
configure_identity
calls=$(cat "$CALLS")
assert_contains "$calls" 'pacman -S --needed --noconfirm -- sudo' 'install mode ensures sudo'
assert_contains "$calls" 'usermod -aG wheel pavel' 'install mode may preserve wheel policy'
assert_file_contains "$install_root/etc/sudoers.d/10-wheel" '%wheel ALL=(ALL:ALL) ALL'
[[ "$calls" != *'useradd '* ]] || { echo 'FAIL: install mode created a user' >&2; exit 1; }
[[ "$calls" != *'passwd '* ]] || { echo 'FAIL: install mode inspected or changed a password' >&2; exit 1; }
[[ "$calls" != *'hostnamectl '* ]] || { echo 'FAIL: install mode changed the hostname' >&2; exit 1; }
