#!/usr/bin/env bash

CHECK_MODE=${CHECK_MODE:-0}
VERBOSE=${VERBOSE:-0}
GET_ARCH_ROOT=${GET_ARCH_ROOT:-}
LOG_FILE=${LOG_FILE:-/dev/null}

system_path() { printf '%s%s\n' "$GET_ARCH_ROOT" "$1"; }
log_info() { printf '[INFO] %s\n' "$*"; }
log_ok()   { printf '[ OK ] %s\n' "$*"; }
log_skip() { printf '[SKIP] %s\n' "$*"; }
log_fail() { printf '[FAIL] %s\n' "$*" >&2; }
die()      { log_fail "$*"; return 1; }

require_root() { (( EUID == 0 )) || die 'Run get-arch as root.'; }
require_arch() { [[ -e "$(system_path /etc/arch-release)" ]] || die 'get-arch must run on Arch Linux.'; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

init_logging() {
  if (( CHECK_MODE )); then LOG_FILE=/dev/null; return; fi
  local dir
  dir=$(system_path /var/log/get-arch)
  mkdir -p "$dir"
  LOG_FILE="$dir/get-arch-$(date +%Y%m%d-%H%M%S).log"
  : >"$LOG_FILE"
}

run_mutation() {
  local label=$1; shift
  if (( CHECK_MODE )); then
    printf '[CHECK] %s:' "$label"; printf ' %q' "$@"; printf '\n'; return 0
  fi
  if (( VERBOSE )); then
    "$@" 2>&1 | tee -a "$LOG_FILE" && { log_ok "$label"; return; }
  else
    "$@" >>"$LOG_FILE" 2>&1 && { log_ok "$label"; return; }
  fi
  log_fail "$label"; return 1
}

run_interactive_mutation() {
  local label=$1; shift
  if (( CHECK_MODE )); then printf '[CHECK] %s\n' "$label"; return 0; fi
  "$@" && log_ok "$label"
}

ensure_service_enabled() {
  local unit=$1
  systemctl is-enabled --quiet "$unit" 2>/dev/null && { log_skip "$unit already enabled"; return; }
  run_mutation "Enable $unit" systemctl enable "$unit"
}

ensure_service_started() {
  local unit=$1
  systemctl is-active --quiet "$unit" 2>/dev/null && { log_skip "$unit already active"; return; }
  run_mutation "Start $unit" systemctl start "$unit"
}

run_as_user_mutation() {
  local user=$1 label=$2
  shift 2
  if (( CHECK_MODE )); then
    printf '[CHECK] %s as %s:' "$label" "$user"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  run_mutation "$label" runuser --pty -u "$user" -- "$@"
}
