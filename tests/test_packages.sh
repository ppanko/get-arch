#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/packages" "$tmp/bin"
cat > "$tmp/packages/desktop" <<'PKGS'
# comment
 git
vim   # inline comment

git
python
PKGS
for g in development data-science documents media utilities aur; do : > "$tmp/packages/$g"; done
REPO_ROOT=$tmp
assert_eq $'git\nvim\ngit\npython' "$(parse_package_file "$tmp/packages/desktop")" 'parse package file'
assert_eq $'git\npython\nvim' "$(load_official_packages)" 'official packages sorted unique'

cat > "$tmp/bin/pacman" <<'PAC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PACMAN_CALLS"
PAC
chmod +x "$tmp/bin/pacman"
export PATH="$tmp/bin:$PATH"
export PACMAN_CALLS="$tmp/pacman-calls"
: > "$PACMAN_CALLS"
CHECK_MODE=1
LOG_FILE="$tmp/log"
ensure_packages git python
assert_eq '' "$(cat "$PACMAN_CALLS")" 'check mode avoids pacman'
CHECK_MODE=0
ensure_packages git python
assert_eq '-S --needed --noconfirm -- git python' "$(cat "$PACMAN_CALLS")" 'normal package invocation'

validate_package_files
