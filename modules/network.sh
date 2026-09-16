#!/usr/bin/env bash
configure_network() {
  ensure_packages networkmanager
  ensure_service_enabled NetworkManager.service
}
