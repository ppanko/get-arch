#!/usr/bin/env bash
configure_laptop() {
  if [[ ${MACHINE_TYPE:-desktop} != laptop ]]; then
    log_skip 'Laptop-specific configuration not required'
    return 0
  fi
  ensure_packages power-profiles-daemon
  ensure_service_enabled power-profiles-daemon.service
}
