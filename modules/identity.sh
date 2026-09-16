#!/usr/bin/env bash

USERNAME=${USERNAME:-}
HOSTNAME_VALUE=${HOSTNAME_VALUE:-}

validate_username() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_hostname() {
  [[ ${#1} -le 63 && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

prompt_identity() {
  while :; do
    read -r -p 'Username: ' USERNAME
    validate_username "$USERNAME" && break
    log_fail 'Invalid username. Use lowercase letters, digits, underscores, and hyphens; do not begin with a hyphen.'
  done
  while :; do
    read -r -p 'Hostname: ' HOSTNAME_VALUE
    validate_hostname "$HOSTNAME_VALUE" && break
    log_fail 'Invalid hostname. Use letters, digits, and hyphens; do not begin or end with a hyphen.'
  done
}

configure_identity() {
  local created_user=0 groups='' sudoers_path sudoers_tmp current_hostname=''
  ensure_packages sudo

  if id -u "$USERNAME" >/dev/null 2>&1; then
    groups=$(id -nG "$USERNAME" 2>/dev/null || true)
    if [[ " $groups " != *' wheel '* ]]; then
      run_mutation "Add $USERNAME to wheel" usermod -aG wheel "$USERNAME"
    else
      log_skip "$USERNAME already belongs to wheel"
    fi
  else
    run_mutation "Create user $USERNAME" useradd -m -G wheel -s /bin/bash "$USERNAME"
    created_user=1
  fi

  sudoers_path=$(system_path /etc/sudoers.d/10-wheel)
  if [[ -f "$sudoers_path" ]] \
      && [[ $(<"$sudoers_path") == '%wheel ALL=(ALL:ALL) ALL' ]] \
      && [[ $(stat -c '%a' "$sudoers_path" 2>/dev/null || true) == 440 ]]; then
    log_skip 'wheel sudo policy already configured'
  else
    sudoers_tmp=$(mktemp)
    printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$sudoers_tmp"
    if ! visudo -cf "$sudoers_tmp" >/dev/null; then
      rm -f "$sudoers_tmp"
      die 'Generated sudoers policy failed validation.'
      return 1
    fi
    run_mutation 'Install wheel sudo policy' install -Dm0440 "$sudoers_tmp" "$sudoers_path"
    rm -f "$sudoers_tmp"
  fi

  current_hostname=$(hostnamectl --static 2>/dev/null || true)
  if [[ $current_hostname == "$HOSTNAME_VALUE" ]]; then
    log_skip 'Hostname already configured'
  else
    run_mutation "Set hostname to $HOSTNAME_VALUE" hostnamectl set-hostname "$HOSTNAME_VALUE"
  fi

  if (( created_user )); then
    run_interactive_mutation "Set password for $USERNAME" passwd "$USERNAME"
  fi
}
