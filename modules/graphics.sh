#!/usr/bin/env bash

installed_kernel_header_packages() {
  local kernel
  for kernel in linux linux-lts linux-zen linux-hardened; do
    if pacman -Qq "$kernel" >/dev/null 2>&1; then
      printf '%s-headers\n' "$kernel"
    fi
  done
}

nvidia_open_supported_device_id() {
  local device=${1#0x}
  device=${device,,}
  [[ $device =~ ^[0-9a-f]{4}$ ]] || return 1
  # Current Arch nvidia-open supports Turing and newer. NVIDIA PCI device IDs
  # for Turing begin at 0x1e00; older generations use lower IDs.
  (( 16#$device >= 16#1e00 ))
}

legacy_nvidia_driver_installed() {
  pacman -Qq 2>/dev/null | grep -Eq '^nvidia-[0-9]+xx-dkms$'
}

configure_graphics() {
  local packages=(mesa) vendor item device legacy_device=''
  local headers=()
  local has_current_nvidia=0 has_legacy_nvidia=0

  append_unique() {
    local candidate=$1 existing
    for existing in "${packages[@]}"; do
      [[ $existing == "$candidate" ]] && return 0
    done
    packages+=("$candidate")
  }

  for vendor in "${GPU_VENDORS[@]}"; do
    case "$vendor" in
      intel) append_unique vulkan-intel ;;
      amd) append_unique vulkan-radeon ;;
      nvidia)
        if ((${#NVIDIA_DEVICE_IDS[@]} == 0)); then
          die 'NVIDIA detected, but its PCI device ID could not be determined; refusing to guess a driver generation.'
          return 1
        fi
        for device in "${NVIDIA_DEVICE_IDS[@]}"; do
          if nvidia_open_supported_device_id "$device"; then
            has_current_nvidia=1
          else
            has_legacy_nvidia=1
            legacy_device=$device
          fi
        done
        ;;
      other) log_info 'Unrecognized GPU vendor detected; installing Mesa without guessing a vendor driver.' ;;
    esac
  done

  if (( has_current_nvidia && has_legacy_nvidia )); then
    die 'Mixed pre-Turing and Turing-or-newer NVIDIA GPUs are not managed automatically; configure the NVIDIA driver stack manually.'
    return 1
  fi

  if (( has_legacy_nvidia )); then
    if legacy_nvidia_driver_installed; then
      log_skip 'Legacy NVIDIA driver already installed; preserving the manually selected legacy driver stack.'
    else
      die "NVIDIA device $legacy_device predates Turing. Current Arch nvidia-open is not appropriate; install the matching legacy NVIDIA DKMS driver, then rerun get-arch."
      return 1
    fi
  elif (( has_current_nvidia )); then
    append_unique nvidia-open-dkms
    append_unique nvidia-utils
    append_unique dkms
    mapfile -t headers < <(installed_kernel_header_packages)
    if ((${#headers[@]} == 0)); then
      die 'NVIDIA detected, but no supported installed kernel was found (linux, linux-lts, linux-zen, linux-hardened).'
      return 1
    fi
    for item in "${headers[@]}"; do append_unique "$item"; done
  fi

  if ((${#GPU_VENDORS[@]} > 1)); then
    append_unique switcheroo-control
  fi

  ensure_packages "${packages[@]}"
}
