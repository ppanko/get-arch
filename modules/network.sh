#!/usr/bin/env bash

network_unit_active_or_enabled() {
  local unit=$1
  if (( INSTALL_MODE )); then
    systemctl --root=/ is-enabled --quiet "$unit" 2>/dev/null
  else
    systemctl is-enabled --quiet "$unit" 2>/dev/null \
      || systemctl is-active --quiet "$unit" 2>/dev/null
  fi
}

conflicting_network_manager() {
  local unit iface

  for unit in systemd-networkd.service dhcpcd.service connman.service; do
    if network_unit_active_or_enabled "$unit"; then
      printf '%s\n' "$unit"
      return 0
    fi
  done

  for iface in "${NETWORK_INTERFACES[@]}"; do
    unit="dhcpcd@$iface.service"
    if network_unit_active_or_enabled "$unit"; then
      printf '%s\n' "$unit"
      return 0
    fi
  done

  if network_unit_active_or_enabled iwd.service \
      && ! network_unit_active_or_enabled NetworkManager.service; then
    printf 'iwd.service\n'
    return 0
  fi

  return 1
}

configure_network() {
  local conflict='' conflict_state='active or enabled'
  conflict=$(conflicting_network_manager || true)
  if [[ -n $conflict ]]; then
    (( INSTALL_MODE )) && conflict_state='enabled in the installed system'
    die "Conflicting network manager $conflict is $conflict_state. Choose NetworkManager in archinstall, or migrate/disable the conflicting manager before rerunning get-arch."
    return 1
  fi
  ensure_packages networkmanager
  ensure_service_enabled NetworkManager.service
}
