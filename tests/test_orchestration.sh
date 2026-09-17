#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source ./get-arch

CALLS=''
record() { CALLS+="$1"$'\n'; }
preflight() { record preflight; }
init_logging() { record init_logging; }
detect_system() { record detect_system; }
print_system_summary() { record print_system_summary; }
prompt_identity() { record prompt_identity; }
upgrade_system() { record upgrade_system; }
configure_identity() { record configure_identity; }
configure_network() { record configure_network; }
configure_audio() { record configure_audio; }
configure_graphics() { record configure_graphics; }
configure_desktop() { record configure_desktop; }
configure_laptop() { record configure_laptop; }
configure_ssh() { record configure_ssh; }
install_declared_official_packages() { record install_declared_official_packages; }
ensure_aur_helper() { record ensure_aur_helper; }
install_aur_packages() { record install_aur_packages; }
log_ok() { :; }

expected=$'preflight\ninit_logging\ndetect_system\nprint_system_summary\nprompt_identity\nupgrade_system\nconfigure_identity\nconfigure_network\nconfigure_audio\nconfigure_graphics\nconfigure_desktop\nconfigure_laptop\nconfigure_ssh\ninstall_declared_official_packages\nensure_aur_helper\ninstall_aur_packages'

CHECK_MODE=0
run_workstation
assert_eq "$expected" "${CALLS%$'\n'}" 'preflight precedes logging and normal orchestration order'

CALLS=''; CHECK_MODE=1
run_workstation
assert_eq "$expected" "${CALLS%$'\n'}" 'check mode follows same planning path'
