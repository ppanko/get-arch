#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export GET_ARCH_AUR_STATE_DIR="$HOME/.local/state/get-arch"
export GET_ARCH_AUR_AUTOSTART_FILE="$HOME/.config/autostart/get-arch-aur-completion.desktop"
mkdir -p "$GET_ARCH_AUR_STATE_DIR" "$(dirname "$GET_ARCH_AUR_AUTOSTART_FILE")" "$tmp/bin"
export CALLS_FILE="$tmp/calls"
: >"$CALLS_FILE"

source scripts/complete-aur

require_normal_user() { :; }

cat >"$tmp/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo:%s\n' "$*" >>"$CALLS_FILE"
SH

cat >"$tmp/bin/paru" <<'SH'
#!/usr/bin/env bash
printf 'paru:%s\n' "$*" >>"$CALLS_FILE"
SH

chmod +x "$tmp/bin/sudo" "$tmp/bin/paru"
export PATH="$tmp/bin:$PATH"

cat >"$PACKAGE_FILE" <<'PKGS'
# pending
foo
bar
PKGS
: >"$AUTOSTART_FILE"

main

calls=$(<"$CALLS_FILE")
assert_contains "$calls" 'sudo:-v' 'first-login completion authenticates once up front'
assert_contains "$calls" 'paru:-S --needed --noconfirm --skipreview --sudoloop -- foo bar' 'first-login completion installs the recorded AUR set without review menus'
[[ ! -e $PACKAGE_FILE ]] || { echo 'FAIL: successful completion kept pending package state' >&2; exit 1; }
[[ ! -e $AUTOSTART_FILE ]] || { echo 'FAIL: successful completion kept autostart entry' >&2; exit 1; }

rm -f "$tmp/bin/paru"
: >"$CALLS_FILE"
cat >"$tmp/bin/git" <<'SH'
#!/usr/bin/env bash
printf 'git:%s\n' "$*" >>"$CALLS_FILE"
target=${!#}
mkdir -p "$target"
SH
cat >"$tmp/bin/makepkg" <<'SH'
#!/usr/bin/env bash
printf 'makepkg:%s\n' "$*" >>"$CALLS_FILE"
SH
chmod +x "$tmp/bin/git" "$tmp/bin/makepkg"

bootstrap_paru
calls=$(<"$CALLS_FILE")
assert_contains "$calls" 'git:clone --depth 1 https://aur.archlinux.org/paru.git' 'paru bootstrap clones the AUR helper'
assert_contains "$calls" 'makepkg:-si --needed --noconfirm' 'paru bootstrap builds as the login user'

cat >"$tmp/bin/paru" <<'SH'
#!/usr/bin/env bash
printf 'paru:%s\n' "$*" >>"$CALLS_FILE"
exit 1
SH
chmod +x "$tmp/bin/paru"
cat >"$PACKAGE_FILE" <<'PKGS'
foo
PKGS
: >"$AUTOSTART_FILE"
set +e
(main >/dev/null 2>&1)
status=$?
set -e
[[ $status -ne 0 ]] || { echo 'FAIL: failed paru install reported success' >&2; exit 1; }
[[ -e $PACKAGE_FILE ]] || { echo 'FAIL: failed completion removed pending package state' >&2; exit 1; }
[[ -e $AUTOSTART_FILE ]] || { echo 'FAIL: failed completion removed retry autostart entry' >&2; exit 1; }
