#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh

CALLS=''
INSTALL_MODE=0
ensure_packages() { CALLS+="packages:$*"$'\n'; }
ensure_service_enabled() { CALLS+="enable:$1"$'\n'; }
ensure_service_started() { CALLS+="start:$1"$'\n'; }
log_skip() { CALLS+="skip:$*"$'\n'; }
log_info() { CALLS+="info:$*"$'\n'; }
die() { CALLS+="die:$*"$'\n'; return 1; }

NETWORK_CONFLICT=''
NETWORK_ENABLED_CONFLICT=''
NETWORK_ACTIVE_CONFLICT=''
NETWORK_SYSTEMCTL_CALLS_FILE=$(mktemp)
trap 'rm -f "$NETWORK_SYSTEMCTL_CALLS_FILE"' EXIT
# Consumed by the sourced network module.
# shellcheck disable=SC2034
NETWORK_INTERFACES=(enp3s0 wlan0)
systemctl() {
  local action unit
  printf '%s\n' "$*" >> "$NETWORK_SYSTEMCTL_CALLS_FILE"
  if [[ ${1:-} == --root=/ ]]; then
    action=${2:-}
    unit=${4:-}
  else
    action=${1:-}
    unit=${3:-${2:-}}
  fi
  if [[ $action == is-enabled && -n ${NETWORK_ENABLED_CONFLICT:-} && $unit == "$NETWORK_ENABLED_CONFLICT" ]]; then
    return 0
  fi
  if [[ $action == is-active && -n ${NETWORK_ACTIVE_CONFLICT:-} && $unit == "$NETWORK_ACTIVE_CONFLICT" ]]; then
    return 0
  fi
  if [[ ($action == is-enabled || $action == is-active) && -n ${NETWORK_CONFLICT:-} && $unit == "$NETWORK_CONFLICT" ]]; then
    return 0
  fi
  return 1
}

after_source_modules() { :; }
source modules/network.sh
source modules/audio.sh
source modules/desktop.sh
source modules/ssh.sh

CALLS=''; configure_network
assert_eq $'packages:networkmanager\nenable:NetworkManager.service' "${CALLS%$'\n'}" 'network module contract'

CALLS=''; NETWORK_CONFLICT=systemd-networkd.service
if configure_network; then echo 'FAIL: conflicting network manager accepted' >&2; exit 1; fi
assert_contains "$CALLS" 'die:Conflicting network manager systemd-networkd.service' 'network manager conflict is actionable'
[[ "$CALLS" != *'packages:networkmanager'* ]] || { echo 'FAIL: NetworkManager installation planned despite conflict' >&2; exit 1; }

CALLS=''; NETWORK_CONFLICT=dhcpcd@enp3s0.service
if configure_network; then echo 'FAIL: per-interface dhcpcd accepted' >&2; exit 1; fi
assert_contains "$CALLS" 'die:Conflicting network manager dhcpcd@enp3s0.service' 'per-interface dhcpcd conflict is detected'
[[ "$CALLS" != *'packages:networkmanager'* ]] || { echo 'FAIL: NetworkManager installation planned despite per-interface dhcpcd conflict' >&2; exit 1; }

CALLS=''; NETWORK_CONFLICT=iwd.service
if configure_network; then echo 'FAIL: standalone iwd accepted without NetworkManager' >&2; exit 1; fi
assert_contains "$CALLS" 'die:Conflicting network manager iwd.service' 'standalone iwd conflict is detected'
NETWORK_CONFLICT=''

CALLS=''; : > "$NETWORK_SYSTEMCTL_CALLS_FILE"; INSTALL_MODE=1
NETWORK_ACTIVE_CONFLICT=systemd-networkd.service
NETWORK_ENABLED_CONFLICT=''
if ! configure_network; then
  echo 'FAIL: install mode treated live-only network activity as a target conflict' >&2
  exit 1
fi
assert_eq $'packages:networkmanager\nenable:NetworkManager.service' "${CALLS%$'\n'}" 'install mode ignores live-only network activity'
network_systemctl_calls=$(<"$NETWORK_SYSTEMCTL_CALLS_FILE")
assert_contains "$network_systemctl_calls" '--root=/ is-enabled --quiet systemd-networkd.service' 'install mode checks target enablement'
[[ $network_systemctl_calls != *'is-active'* ]] || { echo 'FAIL: install mode queried live network activity' >&2; exit 1; }

CALLS=''; : > "$NETWORK_SYSTEMCTL_CALLS_FILE"
NETWORK_ACTIVE_CONFLICT=''
NETWORK_ENABLED_CONFLICT=dhcpcd.service
if configure_network; then echo 'FAIL: target-enabled network manager accepted in install mode' >&2; exit 1; fi
assert_contains "$CALLS" 'die:Conflicting network manager dhcpcd.service' 'install mode rejects target-enabled network conflict'
NETWORK_ENABLED_CONFLICT=''
INSTALL_MODE=0

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
source modules/graphics.sh
source modules/laptop.sh

CALLS=''; GPU_VENDORS=(intel amd); NVIDIA_DEVICE_IDS=(); INSTALLED_KERNEL=''
configure_graphics
assert_eq $'packages:mesa vulkan-intel vulkan-radeon switcheroo-control\nenable:switcheroo-control.service' "${CALLS%$'\n'}" 'intel+amd graphics policy enables switcheroo-control'

CALLS=''; GPU_VENDORS=(nvidia); NVIDIA_DEVICE_IDS=(0x2191); INSTALLED_KERNEL=linux
configure_graphics
assert_eq 'packages:mesa nvidia-open-dkms nvidia-utils dkms linux-headers' "${CALLS%$'\n'}" 'Turing NVIDIA graphics policy'

CALLS=''; GPU_VENDORS=(nvidia); NVIDIA_DEVICE_IDS=(0x1c20); INSTALLED_KERNEL=linux
if configure_graphics; then echo 'FAIL: legacy NVIDIA GPU accepted' >&2; exit 1; fi
assert_contains "$CALLS" 'die:NVIDIA device 0x1c20 predates Turing' 'legacy NVIDIA always fails closed'
[[ "$CALLS" != *'nvidia-open-dkms'* ]] || { echo 'FAIL: legacy NVIDIA requested nvidia-open-dkms' >&2; exit 1; }

CALLS=''; GPU_VENDORS=(nvidia); NVIDIA_DEVICE_IDS=(); INSTALLED_KERNEL=linux
if configure_graphics; then echo 'FAIL: NVIDIA GPU without device ID accepted' >&2; exit 1; fi
assert_contains "$CALLS" 'die:NVIDIA detected, but its PCI device ID could not be determined' 'unknown NVIDIA generation fails closed'

CALLS=''; MACHINE_TYPE=laptop
configure_laptop
assert_eq $'packages:power-profiles-daemon\nenable:power-profiles-daemon.service' "${CALLS%$'\n'}" 'laptop power policy'

CALLS=''; MACHINE_TYPE=desktop
configure_laptop
assert_contains "$CALLS" 'skip:Laptop-specific configuration not required' 'desktop skips laptop policy'
[[ "$CALLS" != *'packages:'* ]] || { echo 'FAIL: desktop requested laptop package' >&2; exit 1; }

run_as_user_mutation() {
  local user=$1 label=$2
  shift 2
  USER_CALL_COUNT=$((USER_CALL_COUNT + 1))
  CALLS+="user:$user:$label:$*"$'\n'
}
USER_CALL_COUNT=0
AUR_FIXTURE=()
load_aur_packages() { ((${#AUR_FIXTURE[@]})) && printf '%s\n' "${AUR_FIXTURE[@]}"; }
USERNAME=pavel
REPO_ROOT=/repo
source modules/aur.sh

orig_path=$PATH
aur_tmp=$(mktemp -d)
trap 'rm -f "$NETWORK_SYSTEMCTL_CALLS_FILE"; rm -rf "$aur_tmp"' EXIT

mkdir -p "$aur_tmp/no-paru-bin"
ln -s "$(command -v cat)" "$aur_tmp/no-paru-bin/cat"
CALLS=''
PATH="$aur_tmp/no-paru-bin" ensure_aur_helper
assert_contains "$CALLS" 'packages:base-devel git rust' 'paru bootstrap dependencies'
assert_contains "$CALLS" 'user:pavel:Build paru AUR helper:bash -lc' 'paru built as user'

cat > "$aur_tmp/paru" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$aur_tmp/paru"
CALLS=''
PATH="$aur_tmp:$orig_path" ensure_aur_helper
[[ "$CALLS" != *'packages:'* && "$CALLS" != *'user:'* ]] || { echo 'FAIL: installed paru bootstrapped again' >&2; exit 1; }

CALLS=''; AUR_FIXTURE=(foo bar)
install_aur_packages
assert_contains "$CALLS" 'user:pavel:Install AUR packages: foo bar:paru -S --needed --noconfirm -- foo bar' 'AUR install runs as user'

CALLS=''; AUR_FIXTURE=()
install_aur_packages
[[ "$CALLS" != *'user:'* ]] || { echo 'FAIL: empty AUR list invoked user mutation' >&2; exit 1; }

run_mutation() {
  local label=$1
  shift
  CALLS+="mutation:$label:$*"$'\n'
}
system_path() { printf '%s\n' "$1"; }
aur_completion_user_home() { printf '/home/pavel\n'; }
id() {
  case "${1:-}" in
    -u|-g) printf '1000\n' ;;
    *) command id "$@" ;;
  esac
}

CALLS=''; USER_CALL_COUNT=0; AUR_FIXTURE=(foo bar); INSTALL_MODE=1
schedule_aur_completion_install_mode
assert_eq 0 "$USER_CALL_COUNT" 'install mode never opens an interactive target-user AUR session'
assert_contains "$CALLS" 'packages:base-devel git rust gnome-terminal' 'install mode stages first-login AUR prerequisites'
assert_contains "$CALLS" 'mutation:Install first-login AUR completion helper:install -Dm0755' 'install mode installs the completion helper'
assert_contains "$CALLS" 'mutation:Record pending AUR package set:install -m0600 -o 1000 -g 1000' 'install mode records the deferred package set for the existing user'
assert_contains "$CALLS" 'mutation:Schedule first-login AUR completion:install -m0644 -o 1000 -g 1000' 'install mode schedules a per-user first-login continuation'
assert_contains "$CALLS" 'info:AUR completion scheduled for the first GNOME login of pavel: foo bar' 'install mode reports the automatic continuation'
[[ "$CALLS" != *'sudo -v'* && "$CALLS" != *'makepkg -si'* && "$CALLS" != *'paru -S'* ]] || {
  echo 'FAIL: install mode attempted interactive AUR authentication/build work inside Archinstall' >&2
  exit 1
}

CALLS=''; USER_CALL_COUNT=0; AUR_FIXTURE=(); INSTALL_MODE=1
schedule_aur_completion_install_mode
assert_eq 0 "$USER_CALL_COUNT" 'empty install-mode AUR set never opens a user session'
assert_contains "$CALLS" 'skip:No AUR packages declared' 'empty install-mode AUR set schedules no continuation'
[[ "$CALLS" != *'mutation:'* ]] || { echo 'FAIL: empty AUR set created completion state' >&2; exit 1; }
