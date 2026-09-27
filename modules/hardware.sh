#!/usr/bin/env bash
configure_hardware_support() {
  ensure_packages gvfs-afc gvfs-gphoto2 gvfs-mtp fwupd smartmontools usbutils
}
