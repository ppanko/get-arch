#!/usr/bin/env bash
configure_audio() {
  ensure_packages pipewire pipewire-alsa pipewire-pulse wireplumber
}
