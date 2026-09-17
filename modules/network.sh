#!/usr/bin/env bash

conflicting_network_manager() {
  local unit
  for unit in systemd-networkd.service dhcpcd.service connman.service; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null \
        || systemctl is-active --quiet "$unit" 2>/dev/null; then
      printf '%s\n' "$unit"
      return 0
    fi
  done
  return 1
}

configure_network() {
  local conflict=''
  conflict=$(conflicting_network_manager || true)
  if [[ -n $conflict ]]; then
    die "Conflicting network manager $conflict is active or enabled. Choose NetworkManager in archinstall, or migrate/disable the conflicting manager before rerunning get-arch."
    return 1
  fi
  ensure_packages networkmanager
  ensure_service_enabled NetworkManager.service
}
