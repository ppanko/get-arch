#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

REPO_ROOT=$repo_root
validate_package_files
official=$(load_official_packages)
aur=$(load_aur_packages)

for required in chromium git r libreoffice-still vlc ufw openai-codex; do
  grep -Fxq "$required" <<< "$official" || {
    printf 'FAIL: canonical package set missing %s\n' "$required" >&2
    exit 1
  }
done

if grep -Fxq openai-codex-bin <<< "$aur"; then
  printf 'FAIL: official openai-codex package retained as AUR openai-codex-bin\n' >&2
  exit 1
fi

all_packages="$official"$'\n'"$aur"
for obsolete in pulseaudio flashplugin pakku xf86-input-synaptics exfat-utils fuse-exfat; do
  if grep -Fxq "$obsolete" <<< "$all_packages"; then
    printf 'FAIL: obsolete package retained: %s\n' "$obsolete" >&2
    exit 1
  fi
done

for module_owned in gdm gnome-control-center gnome-keyring gnome-shell nautilus networkmanager openssh pipewire wireplumber power-profiles-daemon sudo; do
  if grep -Fxq "$module_owned" <<< "$official"; then
    printf 'FAIL: module-owned package retained in declarative package set: %s\n' "$module_owned" >&2
    exit 1
  fi
done
