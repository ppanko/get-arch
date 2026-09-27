#!/usr/bin/env bash

detect_active_ssh_connection() {
  local pid entry parent

  if [[ -n ${SSH_CONNECTION:-} ]]; then
    printf '%s\n' "$SSH_CONNECTION"
    return
  fi

  pid=$PPID
  while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    if [[ -r /proc/$pid/environ ]]; then
      while IFS= read -r -d '' entry; do
        if [[ $entry == SSH_CONNECTION=* ]]; then
          printf '%s\n' "${entry#SSH_CONNECTION=}"
          return
        fi
      done < "/proc/$pid/environ"
    fi
    parent=$(awk '/^PPid:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null || true)
    [[ $parent =~ ^[0-9]+$ && $parent != "$pid" ]] || break
    pid=$parent
  done
}

active_ssh_server_port() {
  local connection=$1
  local client_address client_port server_address server_port extra
  read -r client_address client_port server_address server_port extra <<< "$connection"

  if [[ -z $client_address || -z $client_port || -z $server_address || -z $server_port || -n ${extra:-} ]]; then
    die 'SSH_CONNECTION is malformed; refusing to activate UFW without protecting the active SSH session'
    return 1
  fi
  if [[ ! $server_port =~ ^[0-9]+$ ]]; then
    die "Invalid active SSH server port: $server_port"
    return 1
  fi
  server_port=$((10#$server_port))
  if (( server_port < 1 || server_port > 65535 )); then
    die "Invalid active SSH server port: $server_port"
    return 1
  fi

  printf '%d\n' "$server_port"
}

run_ufw_mutation() {
  local label=$1
  shift
  if (( INSTALL_MODE )); then
    run_mutation "$label" unshare --net -- ufw "$@"
  else
    run_mutation "$label" ufw "$@"
  fi
}

ufw_default_policy_matches() {
  local setting=$1 expected=$2 defaults
  defaults=$(system_path /etc/default/ufw)
  [[ -r $defaults ]] || return 1
  grep -Eq "^[[:space:]]*${setting}=(\"${expected}\"|'${expected}'|${expected})[[:space:]]*(#.*)?$" "$defaults"
}

ensure_ufw_default_policy() {
  local direction=$1 policy=$2 setting=$3 expected=$4
  if (( ! CHECK_MODE )) && ufw_default_policy_matches "$setting" "$expected"; then
    log_skip "UFW default $direction policy already $policy"
    return
  fi
  run_ufw_mutation "Set UFW default $direction policy" default "$policy" "$direction"
}

configure_firewall() {
  local active_connection='' active_port=''

  ensure_packages ufw

  if (( ! INSTALL_MODE )); then
    active_connection=$(detect_active_ssh_connection)
  fi
  if [[ -n $active_connection ]]; then
    active_port=$(active_ssh_server_port "$active_connection") || return
  fi

  run_ufw_mutation 'Allow SSH through UFW' allow 22/tcp
  if [[ -n $active_port && $active_port != 22 ]]; then
    run_ufw_mutation "Allow active SSH port $active_port through UFW" allow "$active_port/tcp"
  fi
  ensure_ufw_default_policy incoming deny DEFAULT_INPUT_POLICY DROP
  ensure_ufw_default_policy outgoing allow DEFAULT_OUTPUT_POLICY ACCEPT
  run_ufw_mutation 'Enable UFW' --force enable
  ensure_service_enabled ufw.service
  ensure_service_started ufw.service
}
