#!/usr/bin/env bash
configure_desktop() {
  ensure_packages gnome-shell gnome-session gnome-control-center \
    gnome-settings-daemon gnome-keyring gdm nautilus
  ensure_service_enabled gdm.service
}
