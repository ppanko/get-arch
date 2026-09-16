#!/usr/bin/env bash
configure_ssh() {
  ensure_packages openssh
  ensure_service_enabled sshd.service
  ensure_service_started sshd.service
}
