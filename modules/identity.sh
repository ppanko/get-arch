#!/usr/bin/env bash

USERNAME=${USERNAME:-}
HOSTNAME_VALUE=${HOSTNAME_VALUE:-}

validate_username() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_hostname() {
  [[ ${#1} -le 63 && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

normal_uid_bounds() {
  local login_defs value uid_min=1000 uid_max=60000
  login_defs=$(system_path /etc/login.defs)
  if [[ -r $login_defs ]]; then
    value=$(awk '$1 == "UID_MIN" { print $2; exit }' "$login_defs")
    [[ $value =~ ^[0-9]+$ ]] && uid_min=$value
    value=$(awk '$1 == "UID_MAX" { print $2; exit }' "$login_defs")
    [[ $value =~ ^[0-9]+$ ]] && uid_max=$value
  fi
  printf '%s %s\n' "$uid_min" "$uid_max"
}

normal_login_users() {
  local username uid shell uid_min uid_max passwd_file
  passwd_file=$(system_path /etc/passwd)
  [[ -r $passwd_file ]] || return 0
  read -r uid_min uid_max < <(normal_uid_bounds)
  while IFS=: read -r username _ uid _ _ _ shell; do
    [[ $uid =~ ^[0-9]+$ ]] || continue
    (( uid >= uid_min && uid <= uid_max )) || continue
    validate_username "$username" || continue
    case "$shell" in
      ''|*/false|*/nologin) continue ;;
    esac
    printf '%s\n' "$username"
  done < "$passwd_file"
}

validate_existing_normal_user() {
  local expected=$1 candidate
  while IFS= read -r candidate; do
    [[ $candidate == "$expected" ]] && return 0
  done < <(normal_login_users)
  return 1
}

validate_target_user() {
  local username=$1 uid uid_min uid_max
  validate_username "$username" || return 1
  if uid=$(id -u "$username" 2>/dev/null); then
    [[ $uid =~ ^[0-9]+$ ]] || return 1
    read -r uid_min uid_max < <(normal_uid_bounds)
    (( uid >= uid_min && uid <= uid_max )) || return 1
  fi
}

user_has_usable_password() {
  local status
  status=$(passwd -S "$1" 2>/dev/null) || return 1
  [[ $status =~ ^[^[:space:]]+[[:space:]]+P([[:space:]]|$) ]]
}

prompt_identity() {
  while :; do
    read -r -p 'Username: ' USERNAME
    validate_target_user "$USERNAME" && break
    log_fail 'Invalid workstation user. Use a normal login username; root and system accounts are not valid.'
  done
  while :; do
    read -r -p 'Hostname: ' HOSTNAME_VALUE
    validate_hostname "$HOSTNAME_VALUE" && break
    log_fail 'Invalid hostname. Use letters, digits, and hyphens; do not begin or end with a hyphen.'
  done
}

select_installed_identity() {
  local hostname_file
  local users=()

  hostname_file=$(system_path /etc/hostname)
  [[ -r $hostname_file ]] || { die 'The installed system has no readable /etc/hostname.'; return 1; }
  HOSTNAME_VALUE=$(<"$hostname_file")
  if ! validate_hostname "$HOSTNAME_VALUE"; then
    die "The installed hostname is invalid: '$HOSTNAME_VALUE'. Return to Archinstall and configure a valid hostname."
    return 1
  fi

  if [[ -n $USERNAME ]]; then
    if ! validate_existing_normal_user "$USERNAME"; then
      die "User '$USERNAME' is not an existing normal login user in the installed system."
      return 1
    fi
  else
    mapfile -t users < <(normal_login_users)
    case ${#users[@]} in
      0)
        die 'No normal login user found in the installed system. Create one in Archinstall before provisioning.'
        return 1
        ;;
      1) USERNAME=${users[0]} ;;
      *)
        die "Multiple normal login users found (${users[*]}). Rerun with --install-mode --user USER."
        return 1
        ;;
    esac
  fi

  log_info "Using installed user $USERNAME and hostname $HOSTNAME_VALUE."
}

ensure_wheel_sudo_policy() {
  local sudoers_path sudoers_tmp
  sudoers_path=$(system_path /etc/sudoers.d/10-wheel)
  if [[ -f "$sudoers_path" ]] \
      && [[ $(<"$sudoers_path") == '%wheel ALL=(ALL:ALL) ALL' ]] \
      && [[ $(stat -c '%a' "$sudoers_path" 2>/dev/null || true) == 440 ]]; then
    log_skip 'wheel sudo policy already configured'
    return 0
  fi

  sudoers_tmp=$(mktemp)
  printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$sudoers_tmp"
  if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf "$sudoers_tmp" >/dev/null; then
      rm -f "$sudoers_tmp"
      die 'Generated sudoers policy failed validation.'
      return 1
    fi
  elif (( CHECK_MODE )); then
    log_info 'sudo is not installed yet; sudoers validation will run after the planned sudo installation.'
  else
    rm -f "$sudoers_tmp"
    die 'visudo is unavailable after installing sudo.'
    return 1
  fi
  run_mutation 'Install wheel sudo policy' install -Dm0440 "$sudoers_tmp" "$sudoers_path"
  rm -f "$sudoers_tmp"
}

configure_identity() {
  local created_user=0 user_exists=0 groups='' current_hostname=''

  if (( INSTALL_MODE )); then
    if ! validate_existing_normal_user "$USERNAME"; then
      die "Refusing install-mode user '$USERNAME': it is not an existing normal login account."
      return 1
    fi

    ensure_packages sudo
    groups=$(id -nG "$USERNAME" 2>/dev/null || true)
    if [[ " $groups " != *' wheel '* ]]; then
      run_mutation "Add $USERNAME to wheel" usermod -aG wheel "$USERNAME"
    else
      log_skip "$USERNAME already belongs to wheel"
    fi
    ensure_wheel_sudo_policy
    return
  fi

  if ! validate_target_user "$USERNAME"; then
    die "Refusing workstation user '$USERNAME': choose a normal login account, not root or a system account."
    return 1
  fi

  ensure_packages sudo

  if id -u "$USERNAME" >/dev/null 2>&1; then
    user_exists=1
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

  ensure_wheel_sudo_policy

  current_hostname=$(hostnamectl --static 2>/dev/null || true)
  if [[ $current_hostname == "$HOSTNAME_VALUE" ]]; then
    log_skip 'Hostname already configured'
  else
    run_mutation "Set hostname to $HOSTNAME_VALUE" hostnamectl set-hostname "$HOSTNAME_VALUE"
  fi

  if (( created_user )); then
    run_interactive_mutation "Set password for $USERNAME" passwd "$USERNAME"
  elif (( user_exists )) && ! user_has_usable_password "$USERNAME"; then
    run_interactive_mutation "Set password for $USERNAME" passwd "$USERNAME"
  else
    log_skip "$USERNAME already has a usable password"
  fi
}
