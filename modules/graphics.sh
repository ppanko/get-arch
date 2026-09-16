#!/usr/bin/env bash

installed_kernel_header_packages() {
  local kernel
  for kernel in linux linux-lts linux-zen linux-hardened; do
    if pacman -Qq "$kernel" >/dev/null 2>&1; then
      printf '%s-headers\n' "$kernel"
    fi
  done
}

configure_graphics() {
  local packages=(mesa) vendor item
  local headers=()

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
        append_unique nvidia-open-dkms
        append_unique nvidia-utils
        append_unique dkms
        mapfile -t headers < <(installed_kernel_header_packages)
        if ((${#headers[@]} == 0)); then
          die 'NVIDIA detected, but no supported installed kernel was found (linux, linux-lts, linux-zen, linux-hardened).'
          return 1
        fi
        for item in "${headers[@]}"; do append_unique "$item"; done
        ;;
      other) log_info 'Unrecognized GPU vendor detected; installing Mesa without guessing a vendor driver.' ;;
    esac
  done

  if ((${#GPU_VENDORS[@]} > 1)); then
    append_unique switcheroo-control
  fi

  ensure_packages "${packages[@]}"
}
