#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/detect.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
GET_ARCH_ROOT=$tmp

mkdir -p "$tmp/sys/class/dmi/id" "$tmp/sys/firmware/efi" \
         "$tmp/sys/class/drm/card0/device" "$tmp/sys/class/drm/card1/device" \
         "$tmp/sys/class/net/lo" "$tmp/sys/class/net/wlan0" \
         "$tmp/sys/class/power_supply/BAT0"
printf '10\n' >"$tmp/sys/class/dmi/id/chassis_type"
printf 'Battery\n' >"$tmp/sys/class/power_supply/BAT0/type"
printf '0x8086\n' >"$tmp/sys/class/drm/card0/device/vendor"
printf '0x1234\n' >"$tmp/sys/class/drm/card0/device/device"
printf '0x10de\n' >"$tmp/sys/class/drm/card1/device/vendor"
printf '0x2191\n' >"$tmp/sys/class/drm/card1/device/device"

assert_eq uefi "$(detect_boot_mode)" 'EFI directory means UEFI'
assert_eq laptop "$(detect_machine_type)" 'portable chassis means laptop'
assert_eq $'intel\nnvidia' "$(detect_gpu_vendors)" 'hybrid GPU vendors are both reported'
assert_eq 0x2191 "$(detect_nvidia_device_ids)" 'NVIDIA PCI device ID is reported'
assert_eq wlan0 "$(detect_network_interfaces)" 'loopback is excluded'

detect_system
assert_eq laptop "$MACHINE_TYPE" 'detect_system exports machine type'
assert_eq 1 "$HAS_BATTERY" 'detect_system exports battery presence'
assert_eq 2 "${#GPU_VENDORS[@]}" 'detect_system exports GPU array'
assert_eq 1 "${#NVIDIA_DEVICE_IDS[@]}" 'detect_system exports NVIDIA device IDs'
assert_eq 0x2191 "${NVIDIA_DEVICE_IDS[0]}" 'detect_system preserves NVIDIA device ID'
