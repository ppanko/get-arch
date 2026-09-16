#!/usr/bin/env bash

detect_architecture() { uname -m; }

detect_boot_mode() {
  [[ -d "$(system_path /sys/firmware/efi)" ]] && printf 'uefi\n' || printf 'bios\n'
}

detect_has_battery() {
  local type_file
  shopt -s nullglob
  for type_file in "$(system_path /sys/class/power_supply)"/*/type; do
    if [[ $(<"$type_file") == Battery ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

detect_machine_type() {
  local chassis_file chassis=''
  chassis_file=$(system_path /sys/class/dmi/id/chassis_type)
  [[ -r "$chassis_file" ]] && chassis=$(<"$chassis_file")
  case "$chassis" in
    8|9|10|11|14|30|31|32) printf 'laptop\n'; return 0 ;;
  esac
  if detect_has_battery; then
    printf 'laptop\n'
  else
    printf 'desktop\n'
  fi
}

map_gpu_vendor() {
  case "${1,,}" in
    0x8086) printf 'intel\n' ;;
    0x1002) printf 'amd\n' ;;
    0x10de) printf 'nvidia\n' ;;
    *) printf 'other\n' ;;
  esac
}

detect_gpu_vendors() {
  local vendor_file
  shopt -s nullglob
  for vendor_file in "$(system_path /sys/class/drm)"/card*/device/vendor; do
    [[ -r "$vendor_file" ]] && map_gpu_vendor "$(<"$vendor_file")"
  done | sort -u
  shopt -u nullglob
}

detect_network_interfaces() {
  local iface_path iface
  shopt -s nullglob
  for iface_path in "$(system_path /sys/class/net)"/*; do
    iface=${iface_path##*/}
    [[ $iface == lo ]] || printf '%s\n' "$iface"
  done | sort -u
  shopt -u nullglob
}

detect_system() {
  SYSTEM_ARCH=$(detect_architecture)
  BOOT_MODE=$(detect_boot_mode)
  MACHINE_TYPE=$(detect_machine_type)
  if detect_has_battery; then HAS_BATTERY=1; else HAS_BATTERY=0; fi
  mapfile -t GPU_VENDORS < <(detect_gpu_vendors)
  mapfile -t NETWORK_INTERFACES < <(detect_network_interfaces)
}
