# Modernize `get-arch` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 2020-era installer/configuration scripts with a small, rerunnable Bash post-install configurator that turns a bootable Arch Linux system into the intended GNOME workstation on both laptops and desktops.

**Architecture:** `get-arch` is a thin Bash orchestrator over three small libraries, focused domain modules, and declarative package lists. System facts come from stable Linux interfaces, identity is prompted at runtime, `--check` suppresses mutations, and each module reconciles current state so rerunning the whole command is the recovery mechanism.

**Tech Stack:** Bash, pacman, systemd, sysfs/procfs, NetworkManager, PipeWire/WirePlumber, GNOME/GDM, current Mesa/NVIDIA packages, `paru`, ShellCheck, plain Bash tests.

**Spec:** `docs/superpowers/specs/2026-09-16-modernize-get-arch-design.md`

## Global Constraints

- This is stage two only. `archinstall` owns disks, filesystems, encryption, bootloader selection, and base-system installation.
- The machine must already boot and have network access sufficient to retrieve the repository and packages.
- Use Bash only; do not introduce Python, Ansible, YAML/TOML, or a general configuration framework.
- Prompt only for username and hostname. Detect hardware/system facts.
- GNOME/GDM is the only desktop implemented in this pass.
- Prefer current Arch/GNOME-native choices: NetworkManager, PipeWire/WirePlumber, Wayland-first GNOME, systemd facilities, GNOME-integrated power management.
- Laptop/desktop and GPU handling are detected system states, not profiles.
- All workstation package groups are installed by default. Groups are organizational, not an interactive chooser.
- Official and AUR packages use separate paths.
- Every mutating operation must be safely rerunnable and become a no-op when already satisfied.
- `--check` may inspect the host and prompt for identity but must make no persistent changes.
- Stop on failure. Do not add rollback, checkpoints, or a second state database.
- Keep `get-arch` thin and keep `lib/common.sh` generic; do not recreate `sharedfuncs`.
- Current-laptop package inventories are review inputs, not tracked generated files.

## Target File Structure

```text
get-arch/
├── get-arch
├── lib/
│   ├── common.sh
│   ├── detect.sh
│   └── packages.sh
├── modules/
│   ├── identity.sh
│   ├── network.sh
│   ├── audio.sh
│   ├── graphics.sh
│   ├── desktop.sh
│   ├── laptop.sh
│   ├── ssh.sh
│   └── aur.sh
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

Packages that exist only to implement a system capability remain module-owned: `networkmanager`, PipeWire packages, GPU drivers, `power-profiles-daemon`, `openssh`, and `sudo`. Package files contain the reproducible workstation application/tool set.

---

### Task 1: Test Harness, CLI, and Common Runtime

**Files:**
- Create: `get-arch`
- Create: `lib/common.sh`
- Create: `tests/run`
- Create: `tests/testlib.sh`
- Create: `tests/test_cli.sh`
- Create: `tests/test_common.sh`

**Interfaces:**
- Produces globals: `CHECK_MODE`, `VERBOSE`, `REPO_ROOT`, `LOG_FILE`
- Produces: `parse_args`, `system_path`, `log_info`, `log_ok`, `log_skip`, `log_fail`, `die`, `init_logging`, `require_root`, `require_arch`, `require_command`, `run_mutation`, `run_interactive_mutation`, `ensure_service_enabled`, `ensure_service_started`

- [ ] **Step 1: Add a minimal Bash test harness**

Create `tests/testlib.sh`:

```bash
#!/usr/bin/env bash
set -u
assert_eq() {
  local expected=$1 actual=$2 message=${3:-}
  [[ "$expected" == "$actual" ]] || {
    printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$message" "$expected" "$actual" >&2
    return 1
  }
}
assert_contains() {
  local haystack=$1 needle=$2 message=${3:-}
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'FAIL: %s\nmissing: %q\n' "$message" "$needle" >&2
    return 1
  }
}
assert_file_contains() { grep -Fq -- "$2" "$1"; }
```

Create executable `tests/run`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for test_file in tests/test_*.sh; do
  printf '==> %s\n' "$test_file"
  bash "$test_file"
done
```

- [ ] **Step 2: Write failing CLI/common tests**

`tests/test_cli.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source ./get-arch
CHECK_MODE=0; VERBOSE=0
parse_args --check --verbose
assert_eq 1 "$CHECK_MODE" '--check'
assert_eq 1 "$VERBOSE" '--verbose'
set +e
output=$(parse_args --bogus 2>&1); status=$?
set -e
assert_eq 2 "$status" 'unknown option status'
assert_contains "$output" 'Unknown option' 'unknown option message'
```

`tests/test_common.sh` must verify `system_path` honors a temporary `GET_ARCH_ROOT`, `CHECK_MODE=1` prevents a `touch`, and normal mode executes it.

Run:

```bash
bash tests/test_cli.sh
bash tests/test_common.sh
```

Expected: FAIL because runtime files/functions do not exist.

- [ ] **Step 3: Implement the common runtime**

Core behavior in `lib/common.sh`:

```bash
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
```

Create sourceable `get-arch` with `set -euo pipefail`, `REPO_ROOT`, `usage`, `parse_args`, a guarded `main`, and no domain logic yet. `--help` exits 0; an unknown option exits 2.

- [ ] **Step 4: Run tests and syntax checks**

```bash
bash tests/test_cli.sh
bash tests/test_common.sh
bash -n get-arch lib/common.sh tests/run tests/testlib.sh tests/test_cli.sh tests/test_common.sh
```

Expected: PASS / exit 0.

- [ ] **Step 5: Commit**

```bash
git add get-arch lib/common.sh tests/
git commit -m "feat: add get-arch runtime skeleton"
```

---

### Task 2: System and Hardware Detection

**Files:**
- Create: `lib/detect.sh`
- Create: `tests/test_detect.sh`
- Modify: `get-arch`

**Interfaces:**
- Produces: `detect_architecture`, `detect_boot_mode`, `detect_has_battery`, `detect_machine_type`, `detect_gpu_vendors`, `detect_network_interfaces`, `detect_system`
- `detect_system` exports: `SYSTEM_ARCH`, `BOOT_MODE`, `MACHINE_TYPE`, `HAS_BATTERY`, arrays `GPU_VENDORS`, `NETWORK_INTERFACES`

- [ ] **Step 1: Write fixture-driven failing tests**

Create a fake root containing:

```text
/sys/class/dmi/id/chassis_type       = 10
/sys/firmware/efi/                   exists
/sys/class/power_supply/BAT0/type    = Battery
/sys/class/drm/card0/device/vendor   = 0x8086
/sys/class/drm/card1/device/vendor   = 0x10de
/sys/class/net/lo/
/sys/class/net/wlan0/
```

Set `GET_ARCH_ROOT` to that tree and assert:

```bash
assert_eq uefi "$(detect_boot_mode)"
assert_eq laptop "$(detect_machine_type)"
assert_eq $'intel\nnvidia' "$(detect_gpu_vendors)"
assert_eq wlan0 "$(detect_network_interfaces)"
detect_system
assert_eq laptop "$MACHINE_TYPE"
assert_eq 1 "$HAS_BATTERY"
assert_eq 2 "${#GPU_VENDORS[@]}"
```

Run `bash tests/test_detect.sh`; expected FAIL.

- [ ] **Step 2: Implement stable sysfs detection**

Use these exact mappings/policies:

```bash
detect_architecture() { uname -m; }
detect_boot_mode() { [[ -d "$(system_path /sys/firmware/efi)" ]] && echo uefi || echo bios; }

map_gpu_vendor() {
  case "${1,,}" in
    0x8086) echo intel ;;
    0x1002) echo amd ;;
    0x10de) echo nvidia ;;
    *) echo other ;;
  esac
}
```

`detect_has_battery` checks `/sys/class/power_supply/*/type` for `Battery`. `detect_machine_type` treats DMI chassis types `8,9,10,11,14,30,31,32` as portable and otherwise falls back to battery presence. `detect_gpu_vendors` reads `/sys/class/drm/card*/device/vendor`, maps vendors, and `sort -u`s them. `detect_network_interfaces` lists `/sys/class/net/*` except `lo`; it never assumes `enp*`/`wlp*`.

`detect_system` populates the documented globals and applies no policy.

- [ ] **Step 3: Source detection and run tests**

Add `source "$REPO_ROOT/lib/detect.sh"` to `get-arch`.

```bash
bash tests/test_detect.sh
./tests/run
bash -n lib/detect.sh
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add get-arch lib/detect.sh tests/test_detect.sh
git commit -m "feat: detect workstation hardware"
```

---

### Task 3: Declarative Package Engine

**Files:**
- Create: `lib/packages.sh`
- Create: `packages/{desktop,development,data-science,documents,media,utilities,aur}`
- Create: `tests/test_packages.sh`
- Modify: `get-arch`

**Interfaces:**
- Produces: `parse_package_file`, `load_official_packages`, `load_aur_packages`, `ensure_packages`, `upgrade_system`, `validate_package_files`, `install_declared_official_packages`

- [ ] **Step 1: Create category files and failing parser tests**

Each package file begins as a single category comment; Task 9 populates the canonical lists.

Test fixture:

```text
# comment
 git
vim   # inline comment

git
python
```

Assert `parse_package_file` returns `git`, `vim`, `git`, `python` in order, while `load_official_packages` across fixture groups returns sorted unique names.

- [ ] **Step 2: Implement parsing and pacman helpers**

```bash
OFFICIAL_PACKAGE_GROUPS=(desktop development data-science documents media utilities)

parse_package_file() {
  awk '{ sub(/[[:space:]]*#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length) print }' "$1"
}

load_official_packages() {
  local group
  for group in "${OFFICIAL_PACKAGE_GROUPS[@]}"; do
    parse_package_file "$REPO_ROOT/packages/$group"
  done | sort -u
}

load_aur_packages() { parse_package_file "$REPO_ROOT/packages/aur" | sort -u; }

ensure_packages() {
  (($#)) || return 0
  run_mutation "Install packages: $*" pacman -S --needed --noconfirm -- "$@"
}

upgrade_system() { run_mutation 'Upgrade Arch system' pacman -Syu --noconfirm; }

install_declared_official_packages() {
  local packages=()
  mapfile -t packages < <(load_official_packages)
  ensure_packages "${packages[@]}"
}
```

`validate_package_files` accepts only nonempty entries matching `^[[:alnum:]@._+:-]+$` after parsing.

Never use standalone `pacman -Sy` or `pacman -Syy`.

- [ ] **Step 3: Test dry-run and normal pacman calls**

Put a fake `pacman` earlier in `PATH`. Assert `CHECK_MODE=1` records no invocation and normal mode records:

```text
-S --needed --noconfirm -- git python
```

- [ ] **Step 4: Run tests and commit**

```bash
./tests/run
bash -n lib/packages.sh
git add get-arch lib/packages.sh packages/ tests/test_packages.sh
git commit -m "feat: add declarative package engine"
```

---

### Task 4: Runtime Identity and Sudo

**Files:**
- Create: `modules/identity.sh`
- Create: `tests/test_identity.sh`
- Modify: `get-arch`

**Interfaces:**
- Produces: `validate_username`, `validate_hostname`, `prompt_identity`, `configure_identity`
- Produces globals: `USERNAME`, `HOSTNAME_VALUE`

- [ ] **Step 1: Write failing validation tests**

```bash
validate_username pavel
! validate_username 'Pavel Smith'
! validate_username '-root'
validate_hostname arch-laptop
! validate_hostname '-arch'
! validate_hostname 'arch_1'
```

- [ ] **Step 2: Implement validation and prompting**

```bash
validate_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
validate_hostname() { [[ ${#1} -le 63 && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; }
```

`prompt_identity` loops until each value validates. Do not persist defaults in the repository.

- [ ] **Step 3: Write idempotence tests with command stubs and `GET_ARCH_ROOT`**

Verify:

```text
existing user       -> no useradd
missing user        -> useradd -m -G wheel -s /bin/bash USER
missing wheel       -> usermod -aG wheel USER
sudoers drop-in     -> /etc/sudoers.d/10-wheel, mode 0440
sudoers content     -> %wheel ALL=(ALL:ALL) ALL\n
same hostname       -> no hostnamectl mutation
newly created user  -> interactive passwd in normal mode, planned only in --check
```

- [ ] **Step 4: Implement `configure_identity`**

Order:

```text
ensure_packages sudo
create user if missing
ensure wheel membership
build temporary sudoers snippet, validate with visudo -cf, install -Dm0440
set hostname only if hostnamectl --static differs
run passwd only for a user created during this run
```

All destination writes and commands must honor `CHECK_MODE`.

- [ ] **Step 5: Verify and commit**

```bash
bash tests/test_identity.sh
./tests/run
bash -n modules/identity.sh
git add get-arch modules/identity.sh tests/test_identity.sh
git commit -m "feat: configure runtime identity"
```

---

### Task 5: Common GNOME Workstation Modules

**Files:**
- Create: `modules/{network,audio,desktop,ssh}.sh`
- Create: `tests/test_modules.sh`
- Modify: `get-arch`

**Interfaces:**
- Produces: `configure_network`, `configure_audio`, `configure_desktop`, `configure_ssh`

- [ ] **Step 1: Write failing contract tests using stubbed helpers**

Capture calls and require:

```text
network:  packages networkmanager; enable NetworkManager.service
audio:    packages pipewire pipewire-alsa pipewire-pulse wireplumber
desktop:  packages gnome-shell gnome-session gnome-control-center gnome-settings-daemon gnome-keyring gdm nautilus; enable gdm.service
ssh:      packages openssh; enable sshd.service; start sshd.service
```

Importantly, the network contract does **not** start NetworkManager during provisioning. The system already has a working connection by precondition; enabling NetworkManager for the next boot avoids disrupting an active installer/network stack mid-run.

- [ ] **Step 2: Implement the modules**

```bash
configure_network() {
  ensure_packages networkmanager
  ensure_service_enabled NetworkManager.service
}

configure_audio() {
  ensure_packages pipewire pipewire-alsa pipewire-pulse wireplumber
}

configure_desktop() {
  ensure_packages gnome-shell gnome-session gnome-control-center \
    gnome-settings-daemon gnome-keyring gdm nautilus
  ensure_service_enabled gdm.service
}

configure_ssh() {
  ensure_packages openssh
  ensure_service_enabled sshd.service
  ensure_service_started sshd.service
}
```

Do not enable global PipeWire services and do not add old Xorg/input-driver configuration.

- [ ] **Step 3: Verify and commit**

```bash
bash tests/test_modules.sh
./tests/run
bash -n modules/*.sh
git add get-arch modules/network.sh modules/audio.sh modules/desktop.sh modules/ssh.sh tests/test_modules.sh
git commit -m "feat: configure GNOME workstation services"
```

---

### Task 6: Graphics and Laptop-Specific Configuration

**Files:**
- Create: `modules/graphics.sh`
- Create: `modules/laptop.sh`
- Modify: `tests/test_modules.sh`
- Modify: `get-arch`

**Interfaces:**
- Consumes: `GPU_VENDORS`, `MACHINE_TYPE`
- Produces: `configure_graphics`, `installed_kernel_header_packages`, `configure_laptop`

- [ ] **Step 1: Add failing policy tests**

Require these outcomes:

```text
GPU_VENDORS=(intel amd)
  -> mesa vulkan-intel vulkan-radeon switcheroo-control

GPU_VENDORS=(nvidia), installed kernel linux
  -> mesa nvidia-open-dkms nvidia-utils dkms linux-headers

MACHINE_TYPE=laptop
  -> power-profiles-daemon

MACHINE_TYPE=desktop
  -> no laptop package request
```

- [ ] **Step 2: Implement graphics policy locally in `graphics.sh`**

Use a local `append_unique` helper and package array. Always begin with `mesa`.

Vendor additions:

```text
intel   -> vulkan-intel
amd     -> vulkan-radeon
nvidia  -> nvidia-open-dkms nvidia-utils dkms + installed kernel headers
>1 GPU vendor -> switcheroo-control
other   -> no guessed vendor driver; retain mesa and emit an informational message
```

`installed_kernel_header_packages` explicitly maps installed `linux`, `linux-lts`, `linux-zen`, and `linux-hardened` to their `*-headers` package. If NVIDIA is detected but none of those kernels is found, fail with an actionable message instead of guessing.

The initial NVIDIA policy intentionally uses the current open kernel-module path. Do not silently install legacy NVIDIA AUR branches. A legacy NVIDIA machine should receive a clear unsupported-driver message and stop so legacy support can be designed explicitly later.

- [ ] **Step 3: Implement laptop policy**

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

- [ ] **Step 4: Verify and commit**

```bash
bash tests/test_modules.sh
./tests/run
bash -n modules/graphics.sh modules/laptop.sh
git add get-arch modules/graphics.sh modules/laptop.sh tests/test_modules.sh
git commit -m "feat: configure detected hardware"
```

---

### Task 7: Isolated AUR Installation

**Files:**
- Create: `modules/aur.sh`
- Modify: `lib/common.sh`
- Modify: `tests/test_common.sh`
- Modify: `tests/test_modules.sh`
- Modify: `get-arch`

**Interfaces:**
- Produces: `run_as_user_mutation`, `ensure_aur_helper`, `install_aur_packages`
- AUR helper: `paru`

- [ ] **Step 1: Test user-scoped mutations**

Stub `runuser`; assert normal mode invokes:

```text
runuser -u USER -- COMMAND...
```

and check mode invokes nothing.

- [ ] **Step 2: Implement `run_as_user_mutation`**

```bash
run_as_user_mutation() {
  local user=$1 label=$2; shift 2
  if (( CHECK_MODE )); then
    printf '[CHECK] %s as %s:' "$label" "$user"; printf ' %q' "$@"; printf '\n'; return 0
  fi
  run_mutation "$label" runuser -u "$user" -- "$@"
}
```

- [ ] **Step 3: Write failing AUR tests**

Verify:

```text
paru already installed -> no bootstrap
paru absent            -> ensure base-devel git rust, build as USERNAME
AUR package install    -> paru runs as USERNAME
empty packages/aur     -> clean no-op
```

- [ ] **Step 4: Implement `paru` bootstrap and installation**

Bootstrap script executed as the target user:

```bash
set -euo pipefail
build_dir="$HOME/.cache/get-arch/paru"
rm -rf "$build_dir"
mkdir -p "$(dirname "$build_dir")"
git clone https://aur.archlinux.org/paru.git "$build_dir"
cd "$build_dir"
makepkg -si --needed --noconfirm
```

Before bootstrap: `ensure_packages base-devel git rust`.

Install declared AUR packages with:

```bash
paru -S --needed --noconfirm -- "${packages[@]}"
```

through `run_as_user_mutation`. `makepkg`/`paru` must never run as root.

- [ ] **Step 5: Verify and commit**

```bash
./tests/run
bash -n lib/common.sh modules/aur.sh
git add get-arch lib/common.sh modules/aur.sh tests/test_common.sh tests/test_modules.sh
git commit -m "feat: add isolated AUR installation"
```

---

### Task 8: End-to-End Orchestration and Check Mode

**Files:**
- Modify: `get-arch`
- Create: `tests/test_orchestration.sh`

**Interfaces:**
- Produces: `preflight`, `print_system_summary`, `run_workstation`, final `main`

- [ ] **Step 1: Write a failing orchestration test**

Stub every dependency and assert exact order:

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

The same planning path must execute under `--check`; mutation helpers suppress actual changes.

- [ ] **Step 2: Implement preflight and summary**

```bash
preflight() {
  require_root
  require_arch
  require_command pacman
  require_command systemctl
  require_command runuser
  validate_package_files
}
```

Do not add a ping-to-Google network test. Package retrieval is the authoritative network operation; README documents connectivity as a precondition.

`print_system_summary` prints architecture, boot mode, machine type, battery presence, GPU vendors, and network interfaces.

- [ ] **Step 3: Implement only sequencing in `run_workstation`**

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

`main` parses options, initializes logging, and calls `run_workstation`.

- [ ] **Step 4: Verify and commit**

```bash
./tests/run
bash get-arch --help
set +e; bash get-arch --bogus; test $? -eq 2
bash -n get-arch lib/*.sh modules/*.sh
git add get-arch tests/test_orchestration.sh
git commit -m "feat: orchestrate workstation configuration"
```

---

### Task 9: Reconcile the Default Package Set Against the Current Laptop

**Files:**
- Modify: `packages/{desktop,development,data-science,documents,media,utilities,aur}`
- Modify: `tests/test_packages.sh`

**Interfaces:**
- Produces the canonical all-on-by-default workstation package set

This task runs on the current Arch laptop because the approved design explicitly uses that machine's explicit-package inventory as an input.

- [ ] **Step 1: Capture inventories outside the repository**

```bash
pacman -Qqen | sort -u > /tmp/get-arch-explicit-packages.txt
pacman -Qqem | sort -u > /tmp/get-arch-foreign-packages.txt
```

Do not commit these files.

- [ ] **Step 2: Seed the review from active old-repo intent**

Start with these current equivalents/candidates:

```text
desktop:
  baobab chromium dconf-editor evince file-roller
  gnome-shell gnome-terminal gdm gnome-shell-extensions xdg-user-dirs

development:
  emacs gcc-fortran tcl tk

data-science:
  gsl

documents:
  libreoffice-fresh
  texlive-basic texlive-latex texlive-latexrecommended
  texlive-latexextra texlive-bibtexextra texlive-mathscience

media:
  gimp vlc

utilities:
  zip unzip unrar htop ntfs-3g dosfstools exfatprogs fuse3

legacy AUR candidates, retained only if still intentionally used:
  megasync transmission-gtk-git teamviewer
```

Do not copy these old implementation packages into canonical lists:

```text
pulseaudio pulseaudio-alsa lib32-libpulse
alsa-plugins lib32-alsa-plugins
xorg-server xf86-input-synaptics xf86-input-mouse xf86-input-keyboard
xf86-video-* intel-dri ati-dri mesa-libgl lib32-mesa-libgl
exfat-utils fuse-exfat flashplugin gnome-screenshot gnome-tweak
jdk8-openjdk pakku grub2-theme-archxion-widescreen
```

Do not automatically replace `jdk8-openjdk`; add a current JDK only if the current laptop or a concrete workstation requirement justifies Java.

- [ ] **Step 3: Review current-laptop additions using explicit rules**

For each package on the laptop but absent from the seed:

1. Add it only if a reinstall should reproduce it as part of the normal workstation.
2. Prefer top-level applications/capabilities over incidentally explicit dependencies.
3. Exclude hardware-specific packages; hardware modules own them.
4. Exclude `networkmanager`, PipeWire/WirePlumber, OpenSSH, sudo, and `power-profiles-daemon`; modules own them.
5. Put each official package in exactly one functional group.
6. Put foreign packages in `packages/aur` only after confirming they are intentionally retained and still available through the AUR path.
7. Drop old candidates no longer intentionally used.

- [ ] **Step 4: Validate official package names live**

```bash
while IFS= read -r pkg; do
  pacman -Si "$pkg" >/dev/null || { echo "Missing official package: $pkg" >&2; exit 1; }
done < <(REPO_ROOT=$PWD; source lib/packages.sh; load_official_packages)
```

Expected: all resolve.

- [ ] **Step 5: Validate selected AUR names without installing them**

For each selected entry, confirm its current AUR package or use `paru -Si PACKAGE` after `paru` exists. Remove stale names instead of keeping aliases.

- [ ] **Step 6: Add regression tests against known obsolete entries**

```bash
all=$(cat packages/*)
for obsolete in pulseaudio flashplugin pakku xf86-input-synaptics exfat-utils fuse-exfat; do
  [[ "$all" != *"$obsolete"* ]] || { echo "obsolete package retained: $obsolete" >&2; exit 1; }
done
validate_package_files
```

- [ ] **Step 7: Verify and commit**

```bash
./tests/run
git add packages/ tests/test_packages.sh
git commit -m "feat: define default workstation packages"
```

---

### Task 10: CI, Documentation, Legacy Removal, and Acceptance

**Files:**
- Create: `.github/workflows/test.yml`
- Modify: `README.md`
- Delete: `install`, `configure`, `configure~`, `sharedfuncs`

**Interfaces:**
- No new runtime API

- [ ] **Step 1: Run ShellCheck before wiring CI**

```bash
shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
```

Install `shellcheck` from official Arch repositories on the development machine if needed. Fix real findings; do not globally suppress warnings.

- [ ] **Step 2: Add deterministic GitHub Actions only**

`.github/workflows/test.yml`:

```yaml
name: test
on:
  push:
    branches: [master]
    paths-ignore: ['docs/**', 'README.md']
  pull_request:
    paths-ignore: ['docs/**', 'README.md']
jobs:
  test:
    runs-on: ubuntu-latest
    container: archlinux:latest
    steps:
      - uses: actions/checkout@v4
      - run: pacman -Syu --noconfirm shellcheck
      - run: bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
      - run: shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
      - run: ./tests/run
```

Do not simulate a bare-metal Arch installation in CI.

- [ ] **Step 3: Rewrite README around the two-stage contract**

README must document:

```text
Purpose
Stage 1: use archinstall; produce a bootable network-connected Arch system
Bootstrap Git if missing: pacman -Syu --needed git
Clone repository
Run ./get-arch --check as root
Run ./get-arch as root
Run ./get-arch --verbose for diagnosis
Username/hostname are the only prompts; passwd is normal system interaction
All package groups are installed by default
Laptop/desktop/GPU behavior is detected
Recovery is fix underlying failure, rerun whole command
Package-maintenance inputs: pacman -Qqen and pacman -Qqem
```

Do not tell a minimal system to use `sudo` before `get-arch` has installed/configured sudo; the bootstrap path is a root shell.

- [ ] **Step 4: Remove the legacy implementation completely**

```bash
git rm install configure configure~ sharedfuncs
```

Do not create `legacy/`; Git history is the archive.

- [ ] **Step 5: Run complete automated verification**

```bash
./tests/run
bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run
```

Expected: all exit 0.

- [ ] **Step 6: Run non-destructive real-system acceptance**

On the current laptop, from a root shell:

```bash
./get-arch --check
```

Verify it reports `laptop`, the actual GPU vendor set, and actual network interfaces. Verify every mutating action is only planned and that packages, files, users, hostname, and services remain unchanged.

On a desktop or desktop-like Arch VM, run the same check and verify `desktop` plus an explicit laptop-module skip.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/test.yml README.md
git rm install configure configure~ sharedfuncs
git commit -m "chore: complete get-arch modernization"
```

---

## Final Verification Before Review

- [ ] `./tests/run` passes.
- [ ] `bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run` exits 0.
- [ ] `shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run` has no findings.
- [ ] `install`, `configure`, `configure~`, and `sharedfuncs` no longer exist.
- [ ] Runtime code/package lists contain none of: `pakku`, `flashplugin`, `pulseaudio-alsa`, `xf86-input-synaptics`, `fuse-exfat`, `CONNECTION=`, `VIDEO_DRIVER=`, `DEVICETYPE=`.
- [ ] `./get-arch --check` on the current laptop makes no persistent change and identifies laptop/GPU state correctly.
- [ ] `./get-arch --check` on a desktop/VM skips laptop-specific work.
- [ ] GitHub Actions passes on the implementation PR.
- [ ] Final diff contains no disk, bootloader, filesystem, encryption, multi-DE, machine-profile, or general config-engine scope.
