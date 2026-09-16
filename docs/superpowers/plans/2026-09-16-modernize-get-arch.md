# Modernize `get-arch` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 2020-era installer/configuration scripts with a small, rerunnable Bash post-install configurator that turns a bootable Arch Linux system into the intended GNOME workstation on both laptops and desktops.

**Architecture:** `get-arch` becomes a thin Bash orchestrator over three small libraries, focused domain modules, and declarative package lists. System facts are detected from stable Linux interfaces, identity is prompted at runtime, mutating operations honor `--check`, and each module reconciles current state so rerunning the full command is the recovery mechanism.

**Tech Stack:** Bash, pacman, systemd, standard Linux sysfs/procfs interfaces, NetworkManager, PipeWire/WirePlumber, GNOME/GDM, current Mesa/NVIDIA driver packages, one AUR helper (`paru`), ShellCheck, plain Bash tests.

**Spec:** `docs/superpowers/specs/2026-09-16-modernize-get-arch-design.md`

## Global Constraints

- This is stage two only: `archinstall` owns disks, filesystems, encryption, bootloader selection, and base-system installation.
- The installed system must already boot and have network access sufficient to retrieve the repository and packages.
- Bash is the implementation language; do not add Python, Ansible, YAML/TOML, or another runtime/configuration framework.
- Runtime prompts are limited to username and hostname; hardware facts are detected.
- GNOME/GDM is the only desktop implemented in this modernization.
- Prefer current Arch- and GNOME-native components: NetworkManager, PipeWire/WirePlumber, Wayland-first GNOME behavior, systemd facilities, and GNOME-integrated power management.
- Laptop/desktop and GPU handling are detected system states, not machine profiles.
- All normal package groups are installed by default; grouping is organizational, not an installer chooser.
- Official repository packages and AUR packages have separate installation paths.
- Mutating operations must be safe to rerun and must become no-ops when the desired state already exists.
- `--check` may inspect the system and prompt for username/hostname but must not make persistent changes.
- A failure stops the run. Do not add rollback transactions, persistent checkpoints, or a second state database.
- Keep the top-level entry point thin and keep `lib/common.sh` from becoming a replacement for the old `sharedfuncs` grab bag.
- The current laptop inventory is an input to package reconciliation, not tracked generated state.

---

## Target File Structure

```text
get-arch/
├── get-arch
├── lib/
│   ├── common.sh          # generic runtime, logging, dry-run, system-path helpers
│   ├── detect.sh          # factual system/hardware inspection only
│   └── packages.sh        # package-list parsing and pacman helpers
├── modules/
│   ├── identity.sh        # username/hostname, user, wheel, sudo, password workflow
│   ├── network.sh         # NetworkManager
│   ├── audio.sh           # PipeWire/WirePlumber
│   ├── graphics.sh        # Intel/AMD/NVIDIA/hybrid graphics
│   ├── desktop.sh         # GNOME/GDM
│   ├── laptop.sh          # laptop-only GNOME-integrated power support
│   ├── ssh.sh             # OpenSSH server
│   └── aur.sh             # paru bootstrap and AUR installation as regular user
├── packages/
│   ├── desktop
│   ├── development
│   ├── data-science
│   ├── documents
│   ├── media
│   ├── utilities
│   └── aur
├── tests/
│   ├── run
│   ├── testlib.sh
│   ├── test_cli.sh
│   ├── test_common.sh
│   ├── test_detect.sh
│   ├── test_packages.sh
│   ├── test_identity.sh
│   ├── test_modules.sh
│   └── test_orchestration.sh
├── .github/workflows/test.yml
└── README.md
```

The package lists contain workstation applications and tools. Packages that exist solely to implement a system capability remain owned by the relevant module: for example, `networkmanager` by `network.sh`, PipeWire packages by `audio.sh`, GPU drivers by `graphics.sh`, `power-profiles-daemon` by `laptop.sh`, `openssh` by `ssh.sh`, and `sudo` by `identity.sh`.

---

### Task 1: Build the Test Harness and Common Runtime

**Files:**
- Create: `get-arch`
- Create: `lib/common.sh`
- Create: `tests/run`
- Create: `tests/testlib.sh`
- Create: `tests/test_cli.sh`
- Create: `tests/test_common.sh`

**Interfaces:**
- Produces: `parse_args "$@"`, globals `CHECK_MODE`, `VERBOSE`, `REPO_ROOT`, `LOG_FILE`
- Produces: `system_path ABSOLUTE_PATH -> string`
- Produces: `log_info`, `log_ok`, `log_skip`, `log_fail`, `die`
- Produces: `init_logging`, `require_root`, `require_arch`, `require_command`
- Produces: `run_mutation LABEL COMMAND...`, `run_interactive_mutation LABEL COMMAND...`
- Produces: `ensure_service_enabled UNIT`, `ensure_service_started UNIT`
- Consumed later by every module and library

- [ ] **Step 1: Add a minimal assertion harness and runner**

Create `tests/testlib.sh`:

```bash
#!/usr/bin/env bash
set -u

assert_eq() {
  local expected=$1 actual=$2 message=${3:-}
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$message" "$expected" "$actual" >&2
    return 1
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 message=${3:-}
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s\nmissing: %q\nin:      %q\n' "$message" "$needle" "$haystack" >&2
    return 1
  fi
}

assert_file_contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || {
    printf 'FAIL: %s does not contain %q\n' "$file" "$needle" >&2
    return 1
  }
}
```

Create `tests/run`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for test_file in tests/test_*.sh; do
  printf '==> %s\n' "$test_file"
  bash "$test_file"
done
```

Make `tests/run` executable.

- [ ] **Step 2: Write failing CLI/common tests**

Create `tests/test_cli.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source ./get-arch

CHECK_MODE=0
VERBOSE=0
parse_args --check --verbose
assert_eq 1 "$CHECK_MODE" '--check enables check mode'
assert_eq 1 "$VERBOSE" '--verbose enables verbose mode'

set +e
output=$(parse_args --bogus 2>&1)
status=$?
set -e
assert_eq 2 "$status" 'unknown options exit 2'
assert_contains "$output" 'Unknown option' 'unknown option is explained'
```

Create `tests/test_common.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
GET_ARCH_ROOT=$tmp
assert_eq "$tmp/etc/hostname" "$(system_path /etc/hostname)" 'system_path honors test root'

marker="$tmp/mutated"
CHECK_MODE=1
run_mutation 'touch marker' touch "$marker"
[[ ! -e "$marker" ]] || { echo 'FAIL: check mode mutated system' >&2; exit 1; }

CHECK_MODE=0
LOG_FILE="$tmp/log"
VERBOSE=0
run_mutation 'touch marker' touch "$marker"
[[ -e "$marker" ]] || { echo 'FAIL: normal mode did not execute mutation' >&2; exit 1; }
```

Run:

```bash
bash tests/test_cli.sh
bash tests/test_common.sh
```

Expected: FAIL because the entry point and common helpers do not exist.

- [ ] **Step 3: Implement the common runtime**

Create `lib/common.sh` with strict, source-safe helpers. Use these exact public semantics:

```bash
#!/usr/bin/env bash

CHECK_MODE=${CHECK_MODE:-0}
VERBOSE=${VERBOSE:-0}
GET_ARCH_ROOT=${GET_ARCH_ROOT:-}
LOG_FILE=${LOG_FILE:-/dev/null}

system_path() {
  printf '%s%s\n' "$GET_ARCH_ROOT" "$1"
}

log_info() { printf '[INFO] %s\n' "$*"; }
log_ok()   { printf '[ OK ] %s\n' "$*"; }
log_skip() { printf '[SKIP] %s\n' "$*"; }
log_fail() { printf '[FAIL] %s\n' "$*" >&2; }
die()      { log_fail "$*"; return 1; }

require_root() {
  (( EUID == 0 )) || die 'Run get-arch as root.'
}

require_arch() {
  [[ -e "$(system_path /etc/arch-release)" ]] || die 'get-arch must run on Arch Linux.'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

init_logging() {
  if (( CHECK_MODE )); then
    LOG_FILE=/dev/null
    return
  fi
  local log_dir
  log_dir=$(system_path /var/log/get-arch)
  mkdir -p "$log_dir"
  LOG_FILE="$log_dir/get-arch-$(date +%Y%m%d-%H%M%S).log"
  : >"$LOG_FILE"
}

run_mutation() {
  local label=$1
  shift
  if (( CHECK_MODE )); then
    printf '[CHECK] %s:' "$label"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  if (( VERBOSE )); then
    if "$@" 2>&1 | tee -a "$LOG_FILE"; then
      log_ok "$label"
    else
      log_fail "$label"
      return 1
    fi
  elif "$@" >>"$LOG_FILE" 2>&1; then
    log_ok "$label"
  else
    log_fail "$label"
    return 1
  fi
}

run_interactive_mutation() {
  local label=$1
  shift
  if (( CHECK_MODE )); then
    printf '[CHECK] %s\n' "$label"
    return 0
  fi
  "$@"
  log_ok "$label"
}

ensure_service_enabled() {
  local unit=$1
  if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    log_skip "$unit already enabled"
  else
    run_mutation "Enable $unit" systemctl enable "$unit"
  fi
}

ensure_service_started() {
  local unit=$1
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    log_skip "$unit already active"
  else
    run_mutation "Start $unit" systemctl start "$unit"
  fi
}
```

Create a sourceable `get-arch` skeleton with `parse_args`, `usage`, and a guarded `main`:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$REPO_ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./get-arch [--check] [--verbose] [--help]
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --check) CHECK_MODE=1 ;;
      --verbose) VERBOSE=1 ;;
      --help) usage; return 10 ;;
      *) printf 'Unknown option: %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done
}

main() {
  local parse_status=0
  parse_args "$@" || parse_status=$?
  [[ $parse_status -eq 10 ]] && return 0
  [[ $parse_status -eq 0 ]] || return "$parse_status"
  init_logging
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run the focused tests**

Run:

```bash
bash tests/test_cli.sh
bash tests/test_common.sh
```

Expected: PASS.

- [ ] **Step 5: Run syntax checks**

Run:

```bash
bash -n get-arch lib/common.sh tests/run tests/testlib.sh tests/test_cli.sh tests/test_common.sh
```

Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add get-arch lib/common.sh tests/
git commit -m "feat: add get-arch runtime skeleton"
```

---

### Task 2: Add Hardware and System Detection

**Files:**
- Create: `lib/detect.sh`
- Create: `tests/test_detect.sh`
- Modify: `get-arch`

**Interfaces:**
- Consumes: `system_path`
- Produces: `detect_architecture -> stdout`
- Produces: `detect_boot_mode -> uefi|bios`
- Produces: `detect_has_battery -> 0|1` through exit status and printable summary via `detect_system`
- Produces: `detect_machine_type -> laptop|desktop`
- Produces: `detect_gpu_vendors -> one vendor per line: intel|amd|nvidia|other`
- Produces: `detect_network_interfaces -> one interface name per line`
- Produces globals after `detect_system`: `SYSTEM_ARCH`, `BOOT_MODE`, `MACHINE_TYPE`, `HAS_BATTERY`, arrays `GPU_VENDORS`, `NETWORK_INTERFACES`

- [ ] **Step 1: Write fixture-driven failing tests**

Create `tests/test_detect.sh` that builds fake sysfs trees instead of depending on the test host:

```bash
#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/detect.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
GET_ARCH_ROOT=$tmp

mkdir -p "$tmp/sys/class/dmi/id" "$tmp/sys/firmware/efi" \
         "$tmp/sys/class/drm/card0/device" "$tmp/sys/class/drm/card1/device" \
         "$tmp/sys/class/net/lo" "$tmp/sys/class/net/wlan0" \
         "$tmp/sys/class/power_supply/BAT0"
printf '10\n' >"$tmp/sys/class/dmi/id/chassis_type"
printf 'Battery\n' >"$tmp/sys/class/power_supply/BAT0/type"
printf '0x8086\n' >"$tmp/sys/class/drm/card0/device/vendor"
printf '0x10de\n' >"$tmp/sys/class/drm/card1/device/vendor"

assert_eq uefi "$(detect_boot_mode)" 'EFI directory means UEFI'
assert_eq laptop "$(detect_machine_type)" 'portable chassis means laptop'
assert_eq $'intel\nnvidia' "$(detect_gpu_vendors)" 'hybrid GPU vendors are both reported'
assert_eq wlan0 "$(detect_network_interfaces)" 'loopback is excluded'

detect_system
assert_eq laptop "$MACHINE_TYPE" 'detect_system exports machine type'
assert_eq 1 "$HAS_BATTERY" 'detect_system exports battery presence'
assert_eq 2 "${#GPU_VENDORS[@]}" 'detect_system exports GPU array'
```

Run:

```bash
bash tests/test_detect.sh
```

Expected: FAIL because `lib/detect.sh` does not exist.

- [ ] **Step 2: Implement stable sysfs-based detection**

Create `lib/detect.sh`. Do not use `enp*`/`wlp*` naming or require `lspci` for baseline detection.

Use these mappings:

```bash
detect_architecture() {
  uname -m
}

detect_boot_mode() {
  [[ -d "$(system_path /sys/firmware/efi)" ]] && printf 'uefi\n' || printf 'bios\n'
}

detect_has_battery() {
  local type_file
  for type_file in "$(system_path /sys/class/power_supply)"/*/type; do
    [[ -f "$type_file" ]] || continue
    [[ $(<"$type_file") == Battery ]] && return 0
  done
  return 1
}

detect_machine_type() {
  local chassis_file chassis
  chassis_file=$(system_path /sys/class/dmi/id/chassis_type)
  if [[ -r "$chassis_file" ]]; then
    chassis=$(<"$chassis_file")
    case "$chassis" in
      8|9|10|11|14|30|31|32) printf 'laptop\n'; return ;;
    esac
  fi
  detect_has_battery && printf 'laptop\n' || printf 'desktop\n'
}

map_gpu_vendor() {
  case "${1,,}" in
    0x8086) printf 'intel\n' ;;
    0x1002|0x1022) printf 'amd\n' ;;
    0x10de) printf 'nvidia\n' ;;
    *) printf 'other\n' ;;
  esac
}

detect_gpu_vendors() {
  local vendor_file
  for vendor_file in "$(system_path /sys/class/drm)"/card*/device/vendor; do
    [[ -r "$vendor_file" ]] || continue
    map_gpu_vendor "$(<"$vendor_file")"
  done | sort -u
}

detect_network_interfaces() {
  local path
  for path in "$(system_path /sys/class/net)"/*; do
    [[ -e "$path" ]] || continue
    [[ ${path##*/} == lo ]] || printf '%s\n' "${path##*/}"
  done | sort
}
```

`detect_system` must populate globals without applying policy:

```bash
detect_system() {
  SYSTEM_ARCH=$(detect_architecture)
  BOOT_MODE=$(detect_boot_mode)
  MACHINE_TYPE=$(detect_machine_type)
  if detect_has_battery; then HAS_BATTERY=1; else HAS_BATTERY=0; fi
  mapfile -t GPU_VENDORS < <(detect_gpu_vendors)
  mapfile -t NETWORK_INTERFACES < <(detect_network_interfaces)
}
```

- [ ] **Step 3: Make the top-level script source detection but do not orchestrate modules yet**

Add:

```bash
source "$REPO_ROOT/lib/detect.sh"
```

- [ ] **Step 4: Run tests and syntax checks**

Run:

```bash
bash tests/test_detect.sh
./tests/run
bash -n lib/detect.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add get-arch lib/detect.sh tests/test_detect.sh
git commit -m "feat: detect workstation hardware"
```

---

### Task 3: Add Declarative Package Parsing and Pacman Helpers

**Files:**
- Create: `lib/packages.sh`
- Create: `packages/desktop`
- Create: `packages/development`
- Create: `packages/data-science`
- Create: `packages/documents`
- Create: `packages/media`
- Create: `packages/utilities`
- Create: `packages/aur`
- Create: `tests/test_packages.sh`
- Modify: `get-arch`

**Interfaces:**
- Consumes: `run_mutation`, `log_skip`, `REPO_ROOT`
- Produces: `parse_package_file FILE -> package names on stdout`
- Produces: `load_official_packages -> sorted unique package names on stdout`
- Produces: `load_aur_packages -> sorted unique package names on stdout`
- Produces: `ensure_packages PACKAGE...`
- Produces: `upgrade_system`
- Produces: `validate_package_files`

- [ ] **Step 1: Create empty category files and write failing parser tests**

Each package file initially contains only a category comment, for example:

```text
# Desktop workstation packages
```

They are populated from the legacy repo and current laptop in Task 9.

Create `tests/test_packages.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/packages" <<'EOF'
# comment
 git
vim   # inline comment

git
python
EOF

actual=$(parse_package_file "$tmp/packages")
assert_eq $'git\nvim\ngit\npython' "$actual" 'parser removes comments and blanks without deduplicating'

mkdir -p "$tmp/repo/packages"
printf '%s\n' git python >"$tmp/repo/packages/development"
printf '%s\n' python r >"$tmp/repo/packages/data-science"
for group in desktop documents media utilities; do : >"$tmp/repo/packages/$group"; done
: >"$tmp/repo/packages/aur"
REPO_ROOT="$tmp/repo"
assert_eq $'git\npython\nr' "$(load_official_packages)" 'official groups are sorted and deduplicated'
```

Run:

```bash
bash tests/test_packages.sh
```

Expected: FAIL.

- [ ] **Step 2: Implement package parsing and installation**

Create `lib/packages.sh` with the exact official group set:

```bash
OFFICIAL_PACKAGE_GROUPS=(desktop development data-science documents media utilities)

parse_package_file() {
  local file=$1
  awk '
    { sub(/[[:space:]]*#.*/, "") }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
    length { print }
  ' "$file"
}

load_official_packages() {
  local group
  for group in "${OFFICIAL_PACKAGE_GROUPS[@]}"; do
    parse_package_file "$REPO_ROOT/packages/$group"
  done | sort -u
}

load_aur_packages() {
  parse_package_file "$REPO_ROOT/packages/aur" | sort -u
}

ensure_packages() {
  (($#)) || return 0
  run_mutation "Install packages: $*" pacman -S --needed --noconfirm -- "$@"
}

upgrade_system() {
  run_mutation 'Upgrade Arch system' pacman -Syu --noconfirm
}

validate_package_files() {
  local file pkg
  for file in "$REPO_ROOT"/packages/*; do
    while IFS= read -r pkg; do
      [[ "$pkg" =~ ^[[:alnum:]@._+:-]+$ ]] || {
        printf 'Invalid package entry %q in %s\n' "$pkg" "$file" >&2
        return 1
      }
    done < <(parse_package_file "$file")
  done
}
```

Do not use `pacman -Sy` or `pacman -Syy` independently. `upgrade_system` is the only database-refresh path and performs a full upgrade.

- [ ] **Step 3: Extend package tests for check mode and validation**

Add a fake `pacman` earlier in `PATH` and assert that `CHECK_MODE=1` does not invoke it; then set `CHECK_MODE=0` and assert the command includes `-S --needed --noconfirm`.

Use:

```bash
mkdir -p "$tmp/bin"
cat >"$tmp/bin/pacman" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/pacman.calls"
EOF
chmod +x "$tmp/bin/pacman"
PATH="$tmp/bin:$PATH"
LOG_FILE="$tmp/log"

CHECK_MODE=1
ensure_packages git
[[ ! -e "$tmp/pacman.calls" ]] || exit 1

CHECK_MODE=0
ensure_packages git python
assert_file_contains "$tmp/pacman.calls" '-S --needed --noconfirm -- git python'
```

- [ ] **Step 4: Source the library and run all tests**

Add to `get-arch`:

```bash
source "$REPO_ROOT/lib/packages.sh"
```

Run:

```bash
./tests/run
bash -n lib/packages.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add get-arch lib/packages.sh packages/ tests/test_packages.sh
git commit -m "feat: add declarative package engine"
```

---

### Task 4: Implement Runtime Identity and Sudo Setup

**Files:**
- Create: `modules/identity.sh`
- Create: `tests/test_identity.sh`
- Modify: `get-arch`

**Interfaces:**
- Consumes: `ensure_packages`, `run_mutation`, `run_interactive_mutation`, `system_path`, `CHECK_MODE`
- Produces: `validate_username NAME`
- Produces: `validate_hostname NAME`
- Produces globals: `USERNAME`, `HOSTNAME_VALUE`
- Produces: `prompt_identity`, `configure_identity`

- [ ] **Step 1: Write failing validation tests**

Create `tests/test_identity.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source lib/common.sh
source lib/packages.sh
source modules/identity.sh

validate_username pavel
! validate_username 'Pavel Smith'
! validate_username '-root'
validate_hostname arch-laptop
! validate_hostname '-arch'
! validate_hostname 'arch_1'
```

Run:

```bash
bash tests/test_identity.sh
```

Expected: FAIL.

- [ ] **Step 2: Implement strict validation and prompting**

Use a conservative Linux username and single-label hostname contract:

```bash
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
    printf 'Invalid username. Use lowercase letters, digits, _ or -, beginning with a letter or _.\n' >&2
  done
  while :; do
    read -r -p 'Hostname: ' HOSTNAME_VALUE
    validate_hostname "$HOSTNAME_VALUE" && break
    printf 'Invalid hostname. Use a single DNS-style hostname label.\n' >&2
  done
}
```

- [ ] **Step 3: Write failing idempotence tests for user/hostname/sudo behavior**

Stub `id`, `useradd`, `usermod`, `hostnamectl`, `visudo`, and `passwd` through test functions or a temporary `PATH`. Verify:

- an existing user is not recreated;
- missing wheel membership results in `usermod -aG wheel USER`;
- `/etc/sudoers.d/10-wheel` is written through the test root with mode `0440`;
- the sudoers content is exactly `%wheel ALL=(ALL:ALL) ALL` plus newline;
- hostname is not reset when already correct;
- password setting is skipped in `--check` and invoked interactively for a newly created user in normal mode.

The expected sudoers fixture is:

```text
%wheel ALL=(ALL:ALL) ALL
```

- [ ] **Step 4: Implement idempotent identity reconciliation**

`configure_identity` must perform, in order:

```bash
ensure_packages sudo
# create user only if `id -u "$USERNAME"` fails
# ensure wheel membership only if `id -nG "$USERNAME"` lacks wheel
# validate and install the dedicated sudoers drop-in
# set hostname only if `hostnamectl --static` differs
# invoke passwd only for a user created during this run
```

For the sudoers file, build a temporary file, validate it with `visudo -cf`, then install it with `install -Dm0440`. In check mode, report the intended write but do not create the temp destination under `/etc`.

Use `useradd -m -G wheel -s /bin/bash "$USERNAME"` for a new user and `usermod -aG wheel "$USERNAME"` for an existing user that lacks membership.

- [ ] **Step 5: Run focused and full tests**

Run:

```bash
bash tests/test_identity.sh
./tests/run
bash -n modules/identity.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add get-arch modules/identity.sh tests/test_identity.sh
git commit -m "feat: configure runtime identity"
```

---

### Task 5: Implement the Common GNOME Workstation Modules

**Files:**
- Create: `modules/network.sh`
- Create: `modules/audio.sh`
- Create: `modules/desktop.sh`
- Create: `modules/ssh.sh`
- Create: `tests/test_modules.sh`
- Modify: `get-arch`

**Interfaces:**
- Consumes: `ensure_packages`, `ensure_service_enabled`, `ensure_service_started`
- Produces: `configure_network`, `configure_audio`, `configure_desktop`, `configure_ssh`

- [ ] **Step 1: Write failing module contract tests**

In `tests/test_modules.sh`, stub the shared helpers so the test captures requested packages/services instead of touching the host:

```bash
#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh

calls=$(mktemp)
trap 'rm -f "$calls"' EXIT
ensure_packages() { printf 'packages:%s\n' "$*" >>"$calls"; }
ensure_service_enabled() { printf 'enable:%s\n' "$1" >>"$calls"; }
ensure_service_started() { printf 'start:%s\n' "$1" >>"$calls"; }

source modules/network.sh
source modules/audio.sh
source modules/desktop.sh
source modules/ssh.sh

configure_network
configure_audio
configure_desktop
configure_ssh

assert_file_contains "$calls" 'packages:networkmanager'
assert_file_contains "$calls" 'enable:NetworkManager.service'
assert_file_contains "$calls" 'packages:pipewire pipewire-alsa pipewire-pulse wireplumber'
assert_file_contains "$calls" 'packages:gnome-shell gnome-session gnome-control-center gnome-settings-daemon gnome-keyring gdm nautilus'
assert_file_contains "$calls" 'enable:gdm.service'
assert_file_contains "$calls" 'packages:openssh'
assert_file_contains "$calls" 'enable:sshd.service'
```

Run:

```bash
bash tests/test_modules.sh
```

Expected: FAIL.

- [ ] **Step 2: Implement NetworkManager ownership**

`modules/network.sh`:

```bash
configure_network() {
  ensure_packages networkmanager
  ensure_service_enabled NetworkManager.service
  ensure_service_started NetworkManager.service
}
```

Do not inspect or branch on wired/wireless interface names.

- [ ] **Step 3: Implement PipeWire/WirePlumber ownership**

`modules/audio.sh`:

```bash
configure_audio() {
  ensure_packages pipewire pipewire-alsa pipewire-pulse wireplumber
}
```

Do not enable system-wide PipeWire services; GNOME user sessions and socket/D-Bus activation own that lifecycle.

- [ ] **Step 4: Implement GNOME/GDM ownership**

`modules/desktop.sh`:

```bash
configure_desktop() {
  ensure_packages \
    gnome-shell gnome-session gnome-control-center gnome-settings-daemon \
    gnome-keyring gdm nautilus
  ensure_service_enabled gdm.service
}
```

Do not install old Xorg input drivers or add a separate Xorg configuration path.

- [ ] **Step 5: Implement SSH ownership**

`modules/ssh.sh`:

```bash
configure_ssh() {
  ensure_packages openssh
  ensure_service_enabled sshd.service
  ensure_service_started sshd.service
}
```

- [ ] **Step 6: Source the modules and run tests**

Add the four module `source` lines to `get-arch`, then run:

```bash
bash tests/test_modules.sh
./tests/run
bash -n modules/*.sh
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add get-arch modules/network.sh modules/audio.sh modules/desktop.sh modules/ssh.sh tests/test_modules.sh
git commit -m "feat: configure GNOME workstation services"
```

---

### Task 6: Implement Graphics and Laptop-Specific Configuration

**Files:**
- Create: `modules/graphics.sh`
- Create: `modules/laptop.sh`
- Modify: `tests/test_modules.sh`
- Modify: `get-arch`

**Interfaces:**
- Consumes globals: `GPU_VENDORS`, `MACHINE_TYPE`
- Consumes: `ensure_packages`, `log_info`, `log_skip`
- Produces: `configure_graphics`, `configure_laptop`
- Produces helper: `installed_kernel_header_packages -> package names`

- [ ] **Step 1: Add failing graphics/laptop tests**

Extend `tests/test_modules.sh` with isolated calls:

```bash
: >"$calls"
source modules/graphics.sh
source modules/laptop.sh

GPU_VENDORS=(intel amd)
configure_graphics
assert_file_contains "$calls" 'packages:mesa vulkan-intel vulkan-radeon switcheroo-control'

: >"$calls"
GPU_VENDORS=(nvidia)
installed_kernel_header_packages() { printf '%s\n' linux-headers; }
configure_graphics
assert_file_contains "$calls" 'packages:mesa nvidia-open-dkms nvidia-utils dkms linux-headers'

: >"$calls"
MACHINE_TYPE=laptop
configure_laptop
assert_file_contains "$calls" 'packages:power-profiles-daemon'

: >"$calls"
MACHINE_TYPE=desktop
configure_laptop
[[ ! -s "$calls" ]] || { echo 'FAIL: desktop received laptop packages' >&2; exit 1; }
```

Run and confirm FAIL.

- [ ] **Step 2: Implement Intel/AMD/hybrid package selection**

`configure_graphics` starts from `mesa`, then adds vendor-specific packages without duplicates:

- Intel: `vulkan-intel`
- AMD: `vulkan-radeon`
- NVIDIA: `nvidia-open-dkms`, `nvidia-utils`, `dkms`, plus headers for installed supported kernels
- More than one detected vendor: `switcheroo-control`

Use an array and a small `append_unique` helper local to `graphics.sh`; do not put graphics policy in `common.sh`.

- [ ] **Step 3: Implement kernel-header discovery for DKMS**

Support the standard Arch kernels explicitly:

```bash
installed_kernel_header_packages() {
  local pkg
  for pkg in linux linux-lts linux-zen linux-hardened; do
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
      printf '%s-headers\n' "$pkg"
    fi
  done
}
```

If NVIDIA is detected and no supported installed kernel package is found, return an actionable failure rather than guessing a header package.

The initial NVIDIA policy is the current `nvidia-open` path. Do not silently install legacy NVIDIA AUR branches. If a machine requires a legacy driver, fail with a message identifying that the automatic path only supports GPUs handled by the current open kernel module and leave legacy support for a separate explicit enhancement.

- [ ] **Step 4: Implement laptop behavior**

`modules/laptop.sh`:

```bash
configure_laptop() {
  if [[ ${MACHINE_TYPE:-desktop} != laptop ]]; then
    log_skip 'Laptop-specific configuration not required'
    return 0
  fi
  ensure_packages power-profiles-daemon
}
```

Do not install TLP alongside `power-profiles-daemon`.

- [ ] **Step 5: Run tests and syntax checks**

Run:

```bash
bash tests/test_modules.sh
./tests/run
bash -n modules/graphics.sh modules/laptop.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add get-arch modules/graphics.sh modules/laptop.sh tests/test_modules.sh
git commit -m "feat: configure detected hardware"
```

---

### Task 7: Bootstrap and Use a Single AUR Helper Safely

**Files:**
- Create: `modules/aur.sh`
- Modify: `lib/common.sh`
- Modify: `tests/test_common.sh`
- Modify: `tests/test_modules.sh`
- Modify: `get-arch`

**Interfaces:**
- Consumes: `USERNAME`, `load_aur_packages`, `ensure_packages`, `run_mutation`, `CHECK_MODE`
- Produces: `run_as_user_mutation USER LABEL COMMAND...`
- Produces: `ensure_aur_helper`, `install_aur_packages`
- AUR helper: `paru`

- [ ] **Step 1: Add a failing non-root execution helper test**

Extend `tests/test_common.sh` by stubbing `runuser` in `PATH` and asserting:

```text
runuser -u pavel -- bash -lc <command>
```

is used in normal mode, while check mode prints the planned action and does not invoke the stub.

- [ ] **Step 2: Implement `run_as_user_mutation`**

Add to `lib/common.sh`:

```bash
run_as_user_mutation() {
  local user=$1 label=$2
  shift 2
  if (( CHECK_MODE )); then
    printf '[CHECK] %s as %s:' "$label" "$user"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  run_mutation "$label" runuser -u "$user" -- "$@"
}
```

- [ ] **Step 3: Write failing AUR module tests**

In `tests/test_modules.sh`, override `command`, `ensure_packages`, `run_as_user_mutation`, and `load_aur_packages` sufficiently to assert:

- `paru` already on `PATH` skips bootstrap;
- absent `paru` ensures `base-devel git rust` before bootstrap;
- bootstrap runs as `USERNAME`;
- AUR package installation runs as `USERNAME`;
- an empty AUR list is a clean no-op.

- [ ] **Step 4: Implement `paru` bootstrap**

Use a disposable build directory inside the target user's home cache, not the repository:

```bash
ensure_aur_helper() {
  command -v paru >/dev/null 2>&1 && { log_skip 'paru already installed'; return 0; }
  ensure_packages base-devel git rust
  local script
  script='set -euo pipefail
build_dir="$HOME/.cache/get-arch/paru"
rm -rf "$build_dir"
mkdir -p "$(dirname "$build_dir")"
git clone https://aur.archlinux.org/paru.git "$build_dir"
cd "$build_dir"
makepkg -si --needed --noconfirm'
  run_as_user_mutation "$USERNAME" 'Bootstrap paru' bash -lc "$script"
}
```

`makepkg` must never run as root.

- [ ] **Step 5: Implement AUR installation**

```bash
install_aur_packages() {
  local packages=()
  mapfile -t packages < <(load_aur_packages)
  ((${#packages[@]})) || { log_skip 'No AUR packages declared'; return 0; }
  run_as_user_mutation "$USERNAME" 'Install AUR packages' \
    paru -S --needed --noconfirm -- "${packages[@]}"
}
```

- [ ] **Step 6: Run tests and syntax checks**

Run:

```bash
./tests/run
bash -n lib/common.sh modules/aur.sh
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add get-arch lib/common.sh modules/aur.sh tests/test_common.sh tests/test_modules.sh
git commit -m "feat: add isolated AUR installation"
```

---

### Task 8: Wire the End-to-End Orchestrator and `--check` Flow

**Files:**
- Modify: `get-arch`
- Create: `tests/test_orchestration.sh`

**Interfaces:**
- Consumes every public function defined in Tasks 1-7
- Produces: `preflight`, `print_system_summary`, `run_workstation`, `main`

- [ ] **Step 1: Write a failing orchestration-order test**

Create `tests/test_orchestration.sh`. Source `get-arch`, replace each orchestration dependency with a function that appends its name to a temp file, and assert this sequence:

```text
preflight
detect_system
print_system_summary
prompt_identity
upgrade_system
configure_identity
configure_network
configure_audio
configure_graphics
configure_desktop
configure_laptop
configure_ssh
install_declared_official_packages
ensure_aur_helper
install_aur_packages
```

Also assert `--check` reaches the same planning sequence while `run_mutation` prevents persistent changes.

- [ ] **Step 2: Add `install_declared_official_packages` to the package library**

In `lib/packages.sh`:

```bash
install_declared_official_packages() {
  local packages=()
  mapfile -t packages < <(load_official_packages)
  ensure_packages "${packages[@]}"
}
```

- [ ] **Step 3: Implement preflight and summary**

`preflight` must:

```bash
require_root
require_arch
require_command pacman
require_command systemctl
require_command runuser
validate_package_files
```

Do not add a ping-to-Google style network check. Package retrieval itself is the authoritative network operation; the README states the connectivity precondition.

`print_system_summary` prints architecture, boot mode, machine type, battery presence, GPU vendors, and network interfaces without changing state.

- [ ] **Step 4: Implement the orchestrator**

`run_workstation` must contain only sequencing:

```bash
run_workstation() {
  preflight
  detect_system
  print_system_summary
  prompt_identity
  upgrade_system
  configure_identity
  configure_network
  configure_audio
  configure_graphics
  configure_desktop
  configure_laptop
  configure_ssh
  install_declared_official_packages
  ensure_aur_helper
  install_aur_packages
  log_ok 'Workstation configuration complete; reboot is recommended.'
}
```

`main` parses arguments, initializes logging, and calls `run_workstation`.

- [ ] **Step 5: Verify help/error paths and full test suite**

Run:

```bash
./tests/run
bash get-arch --help
set +e; bash get-arch --bogus; test $? -eq 2
bash -n get-arch lib/*.sh modules/*.sh
```

Expected: all tests PASS; help exits 0; invalid option exits 2.

- [ ] **Step 6: Commit**

```bash
git add get-arch lib/packages.sh tests/test_orchestration.sh
git commit -m "feat: orchestrate workstation configuration"
```

---

### Task 9: Reconcile and Populate the Default Workstation Package Groups

**Files:**
- Modify: `packages/desktop`
- Modify: `packages/development`
- Modify: `packages/data-science`
- Modify: `packages/documents`
- Modify: `packages/media`
- Modify: `packages/utilities`
- Modify: `packages/aur`
- Modify: `tests/test_packages.sh`

**Interfaces:**
- Consumes the package parser from Task 3
- Produces the canonical all-on-by-default workstation package set

This task must be performed on the current Arch laptop because the approved design explicitly uses its explicit-package inventory as one of the inputs.

- [ ] **Step 1: Capture current explicit package inventories outside the repository**

Run:

```bash
pacman -Qqen | sort -u > /tmp/get-arch-explicit-packages.txt
pacman -Qqem | sort -u > /tmp/get-arch-foreign-packages.txt
```

Do not commit these files.

- [ ] **Step 2: Seed the review from the active package intent in the old `configure`**

Use this classification as the starting review set; it reflects packages/functions actually reached by the old main flow, not commented-out optional modules:

```text
desktop candidates:
  baobab chromium dconf-editor evince file-roller
  gnome-shell gnome-terminal gdm gnome-shell-extensions xdg-user-dirs

development candidates:
  emacs gcc-fortran tcl tk

data-science candidates:
  gsl

documents candidates:
  libreoffice-fresh
  texlive-basic texlive-latex texlive-latexrecommended
  texlive-latexextra texlive-bibtexextra texlive-mathscience

media candidates:
  gimp vlc

utilities candidates:
  zip unzip unrar htop ntfs-3g dosfstools exfatprogs fuse3

legacy AUR candidates to keep only if still intentionally used/current:
  megasync transmission-gtk-git teamviewer
```

The following legacy entries are intentionally **not** copied into package files:

```text
pulseaudio pulseaudio-alsa lib32-libpulse
alsa-plugins lib32-alsa-plugins
xorg-server xf86-input-synaptics xf86-input-mouse xf86-input-keyboard
xf86-video-intel xf86-video-ati vesa-era driver packages
intel-dri ati-dri mesa-libgl lib32-mesa-libgl
exfat-utils fuse-exfat
flashplugin
gnome-screenshot
gnome-tweak
jdk8-openjdk
pakku and its bootstrap dependencies
grub2-theme-archxion-widescreen
```

Reasons are already owned elsewhere: PipeWire replaces the PulseAudio setup, modern GNOME uses libinput/Wayland paths, graphics packages are detected by `graphics.sh`, `exfatprogs` replaces the old exFAT userspace package pairing, Flash is obsolete, the old GNOME screenshot/tweak package names are obsolete/superseded, and bootloader cosmetics are outside the post-install core.

Do **not** automatically replace `jdk8-openjdk` with the current JDK unless the current laptop inventory or an actual workstation requirement justifies Java.

- [ ] **Step 3: Compare the laptop against the seed and categorize additions**

Produce normalized declared candidates in `/tmp`, then use `comm`:

```bash
cat /tmp/get-arch-explicit-packages.txt > /tmp/get-arch-current-official.txt
cat /tmp/get-arch-foreign-packages.txt > /tmp/get-arch-current-foreign.txt
```

For each package present on the laptop but absent from the seed, apply these rules:

1. Add it only if it is part of the normal workstation you want reproduced after reinstall.
2. Do not add dependencies merely because they were manually marked explicit; prefer the highest-level package that represents the capability.
3. Do not add hardware-specific packages; `graphics.sh`/`laptop.sh` own those.
4. Do not add NetworkManager, PipeWire/WirePlumber, OpenSSH, sudo, or `power-profiles-daemon`; their modules own them.
5. Put official packages in exactly one functional group.
6. Put foreign packages in `packages/aur` only after confirming they are intentionally retained and available from the AUR path.
7. Remove old candidates that are no longer intentionally used, even if they still exist in Arch.

- [ ] **Step 4: Validate every official package against the current repositories**

After editing the six official files:

```bash
while IFS= read -r pkg; do
  pacman -Si "$pkg" >/dev/null || {
    printf 'Missing official package: %s\n' "$pkg" >&2
    exit 1
  }
done < <(
  REPO_ROOT=$PWD
  source lib/packages.sh
  load_official_packages
)
```

Expected: every package resolves in configured official repositories.

- [ ] **Step 5: Validate AUR names without installing them**

For every selected `packages/aur` entry, verify its current AUR package page or `paru -Si PACKAGE` once `paru` is available. Remove stale package names rather than carrying compatibility aliases.

- [ ] **Step 6: Add regression assertions for key modernization outcomes**

Extend `tests/test_packages.sh` to assert the canonical lists do **not** contain known obsolete entries:

```bash
all=$(cat packages/*)
for obsolete in pulseaudio flashplugin pakku xf86-input-synaptics exfat-utils fuse-exfat; do
  [[ "$all" != *"$obsolete"* ]] || {
    printf 'FAIL: obsolete package retained: %s\n' "$obsolete" >&2
    exit 1
  }
done
```

Also run `validate_package_files` against the real repository.

- [ ] **Step 7: Run tests**

Run:

```bash
./tests/run
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add packages/ tests/test_packages.sh
git commit -m "feat: define default workstation packages"
```

---

### Task 10: Add Static CI, Rewrite the README, and Remove the Legacy Implementation

**Files:**
- Create: `.github/workflows/test.yml`
- Modify: `README.md`
- Delete: `install`
- Delete: `configure`
- Delete: `configure~`
- Delete: `sharedfuncs`

**Interfaces:**
- No new runtime API
- Produces the documented bootstrap/user workflow and CI verification path

- [ ] **Step 1: Add a failing/static verification command locally**

Before adding CI, run:

```bash
shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
```

If ShellCheck is not installed on the development machine, install `shellcheck` from the official Arch repositories for development only. Fix real findings; do not suppress warnings globally.

- [ ] **Step 2: Add GitHub Actions for deterministic checks only**

Create `.github/workflows/test.yml`:

```yaml
name: test

on:
  push:
    branches: [master]
    paths-ignore:
      - 'docs/**'
      - 'README.md'
  pull_request:
    paths-ignore:
      - 'docs/**'
      - 'README.md'

jobs:
  test:
    runs-on: ubuntu-latest
    container: archlinux:latest
    steps:
      - uses: actions/checkout@v4
      - name: Install test dependencies
        run: pacman -Syu --noconfirm shellcheck
      - name: Bash syntax
        run: bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
      - name: ShellCheck
        run: shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
      - name: Unit tests
        run: ./tests/run
```

CI intentionally does not attempt a fake bare-metal workstation installation.

- [ ] **Step 3: Rewrite the README around the two-stage flow**

The README must contain these concrete sections:

1. **Purpose** — post-install Arch GNOME workstation configurator.
2. **Stage 1: install Arch** — use `archinstall`; obtain a bootable network-connected system. Disk/filesystem/bootloader choices are outside this repository.
3. **Bootstrap Git if needed**:

```bash
pacman -Syu --needed git
```

4. **Retrieve and inspect**:

```bash
git clone https://github.com/ppanko/get-arch.git
cd get-arch
./get-arch --check
```

5. **Configure**:

```bash
./get-arch
```

Run as root; explain that the script prompts only for username/hostname and uses normal `passwd` interaction for a newly created user.

6. **Diagnostics**:

```bash
./get-arch --verbose
```

7. **Package groups** — explain the six official groups plus AUR and that all are installed by default.
8. **Laptop/desktop behavior** — detection is automatic; no machine profile exists.
9. **Recovery** — fix the failed underlying operation and rerun the whole command.
10. **Package inventory maintenance** — document:

```bash
pacman -Qqen
pacman -Qqem
```

as review inputs when refreshing defaults.

- [ ] **Step 4: Remove all four legacy files**

Delete:

```text
install
configure
configure~
sharedfuncs
```

Do not retain a `legacy/` copy. Git history is the archive.

- [ ] **Step 5: Run the complete automated verification**

Run:

```bash
./tests/run
bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
```

Expected: all commands exit 0.

- [ ] **Step 6: Run non-destructive acceptance checks on real Arch systems**

On the current laptop:

```bash
sudo ./get-arch --check
```

Verify the summary reports `laptop`, the actual GPU vendor set, and the expected network interfaces. Verify every subsequent action is shown as `[CHECK]`/informational output and no packages, files, users, hostnames, or services change.

On a desktop or desktop-like Arch VM:

```bash
sudo ./get-arch --check
```

Verify it reports `desktop` and explicitly skips laptop-specific configuration.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/test.yml README.md
git rm install configure configure~ sharedfuncs
git commit -m "chore: complete get-arch modernization"
```

---

## Final Verification Before Review

- [ ] Run all deterministic tests:

```bash
./tests/run
```

Expected: PASS.

- [ ] Run parser/static checks:

```bash
bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
```

Expected: exit 0 with no ShellCheck findings.

- [ ] Verify no legacy implementation remains:

```bash
for path in install configure configure~ sharedfuncs; do
  [[ ! -e "$path" ]] || { echo "legacy file remains: $path"; exit 1; }
done
```

- [ ] Verify forbidden old implementation/package terms are absent from runtime code and canonical package lists (design/history docs excluded):

```bash
! grep -RInE 'pakku|flashplugin|pulseaudio-alsa|xf86-input-synaptics|fuse-exfat|CONNECTION=|VIDEO_DRIVER=|DEVICETYPE=' \
  get-arch lib modules packages README.md
```

- [ ] Verify `--check` on the current laptop makes no persistent changes and identifies the laptop/GPU correctly.

- [ ] Verify GitHub Actions passes on the implementation PR.

- [ ] Review the final diff against `docs/superpowers/specs/2026-09-16-modernize-get-arch-design.md`, specifically checking that no disk, bootloader, filesystem, encryption, multi-DE, profile, or general config-engine scope has re-entered the implementation.
