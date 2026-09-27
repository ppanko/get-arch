#!/usr/bin/env bash
configure_bluetooth() {
  ensure_packages bluez bluez-utils
  ensure_service_enabled bluetooth.service
  ensure_service_started bluetooth.service
}
