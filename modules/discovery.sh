#!/usr/bin/env bash

systemd_resolved_conflicts_with_discovery() {
  if (( INSTALL_MODE )); then
    systemctl --root=/ is-enabled --quiet systemd-resolved.service 2>/dev/null
  else
    systemctl is-enabled --quiet systemd-resolved.service 2>/dev/null \
      || systemctl is-active --quiet systemd-resolved.service 2>/dev/null
  fi
}

configure_discovery() {
  local conflict_state='active or enabled'
  if systemd_resolved_conflicts_with_discovery; then
    (( INSTALL_MODE )) && conflict_state='enabled in the installed system'
    die "systemd-resolved.service is $conflict_state; refusing to enable Avahi because get-arch does not infer resolved or per-connection mDNS ownership. Disable systemd-resolved before rerunning get-arch, or manage the discovery stack outside get-arch."
    return 1
  fi

  ensure_packages avahi gvfs-dnssd
  ensure_service_enabled avahi-daemon.service
  ensure_service_started avahi-daemon.service
}
