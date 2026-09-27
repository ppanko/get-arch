#!/usr/bin/env bash
configure_printing() {
  ensure_packages cups system-config-printer
  ensure_service_enabled cups.socket
  ensure_service_started cups.socket
}
