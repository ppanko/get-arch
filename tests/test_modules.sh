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
