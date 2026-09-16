#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh

CALLS=''
ensure_packages() { CALLS+="packages:$*"$'\n'; }
ensure_service_enabled() { CALLS+="enable:$1"$'\n'; }
ensure_service_started() { CALLS+="start:$1"$'\n'; }
log_skip() { CALLS+="skip:$*"$'\n'; }
log_info() { CALLS+="info:$*"$'\n'; }

after_source_modules() { :; }
source modules/network.sh
source modules/audio.sh
source modules/desktop.sh
source modules/ssh.sh

CALLS=''; configure_network
assert_eq $'packages:networkmanager\nenable:NetworkManager.service' "${CALLS%$'\n'}" 'network module contract'

CALLS=''; configure_audio
assert_eq 'packages:pipewire pipewire-alsa pipewire-pulse wireplumber' "${CALLS%$'\n'}" 'audio module contract'

CALLS=''; configure_desktop
assert_eq $'packages:gnome-shell gnome-session gnome-control-center gnome-settings-daemon gnome-keyring gdm nautilus\nenable:gdm.service' "${CALLS%$'\n'}" 'desktop module contract'

CALLS=''; configure_ssh
assert_eq $'packages:openssh\nenable:sshd.service\nstart:sshd.service' "${CALLS%$'\n'}" 'ssh module contract'

pacman() {
  if [[ ${1:-} == -Qq && ${2:-} == "${INSTALLED_KERNEL:-}" ]]; then
    return 0
  fi
  return 1
}
die() { CALLS+="die:$*"$'\n'; return 1; }
source modules/graphics.sh
source modules/laptop.sh

CALLS=''; GPU_VENDORS=(intel amd); INSTALLED_KERNEL=''
configure_graphics
assert_eq 'packages:mesa vulkan-intel vulkan-radeon switcheroo-control' "${CALLS%$'\n'}" 'intel+amd graphics policy'

CALLS=''; GPU_VENDORS=(nvidia); INSTALLED_KERNEL=linux
configure_graphics
assert_eq 'packages:mesa nvidia-open-dkms nvidia-utils dkms linux-headers' "${CALLS%$'\n'}" 'nvidia graphics policy'

CALLS=''; MACHINE_TYPE=laptop
configure_laptop
assert_eq 'packages:power-profiles-daemon' "${CALLS%$'\n'}" 'laptop power policy'

CALLS=''; MACHINE_TYPE=desktop
configure_laptop
assert_contains "$CALLS" 'skip:Laptop-specific configuration not required' 'desktop skips laptop policy'
[[ "$CALLS" != *'packages:'* ]] || { echo 'FAIL: desktop requested laptop package' >&2; exit 1; }

run_as_user_mutation() {
  local user=$1 label=$2
  shift 2
  CALLS+="user:$user:$label:$*"$'\n'
}
AUR_FIXTURE=()
load_aur_packages() { ((${#AUR_FIXTURE[@]})) && printf '%s\n' "${AUR_FIXTURE[@]}"; }
USERNAME=pavel
source modules/aur.sh

orig_path=$PATH
aur_tmp=$(mktemp -d)
trap 'rm -rf "$aur_tmp"' EXIT

CALLS=''; PATH=/usr/bin:/bin
ensure_aur_helper
assert_contains "$CALLS" 'packages:base-devel git rust' 'paru bootstrap dependencies'
assert_contains "$CALLS" 'user:pavel:Build paru AUR helper:bash -lc' 'paru built as user'

cat > "$aur_tmp/paru" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$aur_tmp/paru"
PATH="$aur_tmp:$orig_path"
CALLS=''
ensure_aur_helper
[[ "$CALLS" != *'packages:'* && "$CALLS" != *'user:'* ]] || { echo 'FAIL: installed paru bootstrapped again' >&2; exit 1; }

CALLS=''; AUR_FIXTURE=(foo bar)
install_aur_packages
assert_contains "$CALLS" 'user:pavel:Install AUR packages: foo bar:paru -S --needed --noconfirm -- foo bar' 'AUR install runs as user'

CALLS=''; AUR_FIXTURE=()
install_aur_packages
[[ "$CALLS" != *'user:'* ]] || { echo 'FAIL: empty AUR list invoked user mutation' >&2; exit 1; }
