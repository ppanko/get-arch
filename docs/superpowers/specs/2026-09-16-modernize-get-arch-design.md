# Modernize `get-arch`

## Purpose

Modernize `get-arch` into a small, maintainable post-install configurator for Arch Linux workstations. The repository should preserve the useful intent of the current scripts while removing machine-specific assumptions, outdated package choices, obsolete implementation patterns, and installation logic that is better owned by `archinstall`.

The result should remain easy to understand and runnable from a fresh Arch shell with minimal prerequisites.

## Scope

`get-arch` will become the second stage of a two-stage installation workflow:

1. Install a minimal, bootable Arch system with `archinstall`.
2. Reboot into that system, retrieve `get-arch`, and run it as root to configure a complete GNOME workstation.

`get-arch` will not own disk partitioning, filesystems, encryption, bootloader selection, or base-system installation. Those responsibilities belong to `archinstall`.

The initial modernization targets laptops and desktops. Hardware-specific behavior is detected rather than selected through machine profiles.

### Post-install preconditions

Before `get-arch` runs, the installed system must be bootable and have working network connectivity sufficient to retrieve the repository. The README should make this bootstrap boundary explicit. If Git is not included in the base installation, the bootstrap instructions may install Git with `pacman` before cloning; that one retrieval prerequisite is not considered workstation configuration.

## Design principles

- Use Bash as the implementation language. A fresh Arch system already provides the shell environment needed to run the tool.
- Detect facts about the machine instead of asking the user to configure them manually.
- Prompt only for values that are genuinely installation-specific and cannot be safely inferred.
- Treat workstation choices as repository policy rather than presenting a long interactive installer wizard.
- Preserve useful behavior from the current repository, but do not preserve obsolete technology choices merely for compatibility.
- Prefer current Arch and GNOME-native components with low maintenance burden.
- Keep modules explicit and small instead of introducing a general task engine or configuration language.
- Make rerunning the entire command the normal recovery path after a partial failure.
- Keep official repository packages and AUR packages operationally separate.

## Runtime model

After the base system has been installed and booted:

```text
retrieve get-arch
    ↓
run ./get-arch as root
    ↓
preflight checks
    ↓
detect system and hardware
    ↓
prompt for username and hostname
    ↓
create/configure user
    ↓
configure common workstation
    ↓
apply hardware-specific configuration
    ↓
install official package groups
    ↓
bootstrap AUR helper as regular user
    ↓
install AUR package group
    ↓
report completion and any follow-up actions
```

The normal invocation is:

```bash
./get-arch
```

Two additional execution modes should be supported from the first implementation:

```bash
./get-arch --check
./get-arch --verbose
```

`--check` performs preflight checks and detection, prompts for username and hostname so identity-dependent actions can be evaluated, then reports the actions that would be taken without modifying the system. `--verbose` exposes underlying command output for diagnosis while normal execution keeps terminal output concise.

No persistent checkpoint database is required. The installed system is the source of truth.

## Runtime input

The initial runtime questionnaire is intentionally small:

- username
- hostname

Passwords are never read, stored, or processed by `get-arch`; the script invokes the normal system password-setting command where required.

Hardware state such as machine type, GPU vendor, CPU architecture, firmware mode, and network devices is not prompted for.

A general-purpose configuration file is not required for the initial modernization. If future requirements establish a real need for persistent overrides, one can be added without changing the module boundaries.

## Workstation policy

The default result is a complete GNOME workstation. All normal package groups are installed by default; package grouping is organizational and supports maintenance and auditing rather than an installation chooser.

Initial platform choices should be selected based on current Arch support and GNOME integration rather than inherited from the existing scripts. The intended direction is:

- GNOME with GDM as the desktop environment and display manager.
- NetworkManager for networking because it integrates naturally with GNOME and handles wired, wireless, VPN, and connection switching without custom interface logic.
- PipeWire with WirePlumber for audio and multimedia policy.
- GNOME's normal Wayland-first behavior rather than explicitly building an Xorg-oriented workstation.
- Current kernel/Mesa/NVIDIA paths selected from detected graphics hardware.
- GNOME-integrated laptop power management by default rather than carrying forward the old TLP setup without evidence that it is needed.
- Native systemd facilities wherever they already solve the required service-management problem.
- One current AUR helper, bootstrapped as a regular user, for packages that are genuinely outside the official repositories.

These are implementation choices, not compatibility requirements. During implementation, obsolete package names and superseded components from the current repository should be replaced with current equivalents.

## Automatic detection

`lib/detect.sh` owns factual system inspection. Detection should cover only facts that materially affect configuration, including:

- laptop versus desktop characteristics
- CPU architecture
- GPU vendor or vendors, including hybrid graphics
- firmware or boot mode when relevant to a post-install decision
- presence of battery hardware
- network hardware when relevant to validation or diagnostics

Detection should use stable system interfaces and standard tools available on Arch rather than assumptions about interface names such as `enp*` or `wlp*`.

Detection is not a policy engine. It reports facts; modules decide what those facts imply for the desired workstation state.

The program should not attempt to infer destructive installation choices such as target disks. Those choices are outside the scope of `get-arch`.

## Repository structure

The target structure is:

```text
get-arch/
├── get-arch
├── lib/
│   ├── common.sh
│   ├── detect.sh
│   └── packages.sh
├── modules/
│   ├── identity.sh
│   ├── desktop.sh
│   ├── network.sh
│   ├── audio.sh
│   ├── graphics.sh
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
└── README.md
```

The top-level `get-arch` script is an orchestrator. It should contain sequencing and argument handling but little domain logic.

`lib/common.sh` contains only truly generic helpers such as logging, root/preflight checks, error handling, and command wrappers.

`lib/detect.sh` contains system inspection.

`lib/packages.sh` parses package files and coordinates package installation.

Domain-specific logic stays in the corresponding module. The project should not recreate the current `sharedfuncs` pattern as another general-purpose grab bag.

## Module responsibilities

### Identity

`modules/identity.sh` prompts for username and hostname, validates them, creates the regular user if necessary, configures wheel membership and sudo access, sets the hostname, and invokes the normal password-setting workflow when required.

Sudo customization should use a dedicated file under `/etc/sudoers.d/` rather than directly editing the main sudoers file when possible.

### Network

`modules/network.sh` installs and enables the selected modern network stack. It should not ask the user to choose wired versus wireless operation and should not contain interface-name heuristics.

### Audio

`modules/audio.sh` installs the current PipeWire/WirePlumber stack and any compatibility packages required by the workstation package set. It should not preserve PulseAudio-specific configuration from the current repository unless a current package explicitly requires compatibility support.

### Graphics

`modules/graphics.sh` consumes detected GPU information and installs the appropriate current graphics stack. Intel, AMD, NVIDIA, and hybrid configurations should be handled as detected system states rather than a `VIDEO_DRIVER` setting.

The implementation should avoid legacy Xorg-driver assumptions that are no longer required on a modern GNOME/Wayland system.

### Desktop

`modules/desktop.sh` configures GNOME and GDM. GNOME is the only desktop implemented in the initial modernization, but the module boundary should avoid making the rest of the repository depend on GNOME-specific internals.

### Laptop

`modules/laptop.sh` is additive. It executes only when laptop characteristics are detected and configures the current preferred power-management and portable-hardware support needed by the GNOME workstation.

A desktop receives the common workstation configuration and simply skips laptop-specific work. There is no separate desktop profile.

### SSH

`modules/ssh.sh` installs OpenSSH and enables the server as part of the standard workstation policy.

### AUR

`modules/aur.sh` bootstraps one current AUR helper and runs AUR package installation as the regular user, never as root. AUR failures should be clearly distinguishable from official repository package failures.

## Package model

Package files are plain text, one package name per line, with blank lines and `#` comments allowed.

Example:

```text
# Development
git
base-devel
gcc
python
r
```

The official package groups are:

- `desktop`
- `development`
- `data-science`
- `documents`
- `media`
- `utilities`

`aur` contains packages that genuinely require the AUR path.

All groups are installed by default. The files are grouped for ownership, review, and auditing, not to create an interactive selection UI.

Hardware-derived packages such as GPU drivers do not belong in these lists. Their modules own them.

There is intentionally no post-install `base` package group because base-system ownership belongs to `archinstall`.

When practical, official package lists should be combined, comments and blank lines removed, duplicate names eliminated, and installation performed in a small number of `pacman --needed` transactions rather than one process per package.

## Package migration and reconciliation

The initial package baseline is constructed from three sources:

1. Packages currently declared in `configure`.
2. Current Arch replacements for entries that are obsolete, renamed, superseded, or no longer necessary.
3. Explicitly installed packages on the user's current Arch laptop.

The existing repository is the seed, not the final authority. The current laptop inventory is used to identify additions that have become part of the normal workstation since development stopped.

For reconciliation, the current laptop should export at least:

```bash
pacman -Qqen > explicit-packages.txt
pacman -Qqem > foreign-packages.txt
```

These inventory files are review inputs and should not become permanent tracked state merely because they were generated.

Packages discovered on the laptop should be classified and reviewed rather than blindly committed. Experiments, obsolete software, and incidentally explicit dependencies should be excluded from the canonical workstation package set.

A later `./get-arch packages audit` command may compare repository-declared packages against explicitly installed packages and report tracked, untracked, missing, and foreign/AUR differences. This audit capability belongs in the architecture but is not required to block the first modernization implementation if it would expand the initial change unnecessarily.

## Execution and idempotence

The scripts should use strict Bash behavior, including `set -euo pipefail` where compatible with the implementation.

Each module should treat an already-correct system state as success. Examples include:

- `pacman --needed` for package installation
- checking whether a user or group membership already exists before creating it
- checking service enablement before changing it
- writing dedicated configuration snippets rather than repeatedly appending lines
- checking whether a desired file state already exists before modifying it

A failure stops further configuration. The normal recovery procedure is to correct the underlying problem and rerun `./get-arch`; previously successful modules should cheaply confirm their desired state and continue.

The project will not implement a rollback system or its own persistent execution-state database.

## Output and logging

Normal terminal output should be concise and structured around steps, for example:

```text
[ OK ] NetworkManager installed
[ OK ] NetworkManager enabled
[SKIP] user already exists
[ OK ] PipeWire packages installed
[FAIL] graphics: package installation failed
```

Detailed command output can be captured in a timestamped log and exposed directly with `--verbose`.

The final summary should state what completed and identify any explicit follow-up action, such as rebooting.

## Testing

Testing should focus on behavior that can be made deterministic outside a full bare-metal installation.

Initial coverage should include:

- shell/static analysis of Bash sources
- argument parsing and mode selection
- parsing, comment removal, and deduplication of package files
- validation of package-file structure
- hardware-detection parsing where fixtures or mocked system output make this practical
- identity input validation
- idempotent helper behavior
- dry-run/check-mode behavior

CI should not pretend to prove a complete Arch workstation installation. Integration behavior that requires real hardware or a live Arch environment should remain observable and easy to diagnose rather than hidden behind unrealistic mocks.

## Migration from the current repository

The current `install`, `configure`, `sharedfuncs`, and accidental `configure~` files are transitional inputs only.

Implementation should extract their still-useful intent, migrate it into the new structure, and then remove the legacy files rather than retaining two competing configuration paths.

Examples of intent worth preserving include user/sudo setup, SSH, networking, graphics support, desktop setup, workstation applications, development tools, document tooling, media tooling, and laptop-specific support.

Examples of implementation that should not be preserved merely for compatibility include Pakku-specific AUR logic, PulseAudio-specific setup, old Xorg input/video-driver assumptions, wired/wireless branching, direct interface-name probing, direct editing of monolithic system configuration files where drop-ins exist, and hard-coded hardware or identity values.

## Explicit non-goals

The first modernization does not aim to provide:

- disk partitioning or filesystem creation
- bootloader installation
- encryption setup
- a replacement for `archinstall`
- multiple desktop environments
- machine-specific profiles
- a YAML/TOML configuration system
- an interactive package-group chooser
- rollback transactions
- persistent checkpoints
- arbitrary per-module execution flags
- a general configuration-management framework

These can be reconsidered only when a concrete requirement justifies them.

## Success criteria

The modernization is successful when:

- a user can install a minimal Arch system with `archinstall`, reboot into a network-connected system, retrieve this repository, and run one Bash entry point to obtain the intended GNOME workstation;
- the same code path supports both laptops and desktops through detection rather than separate profiles;
- username and hostname are runtime inputs rather than repository-specific constants;
- hardware facts are detected rather than hard-coded;
- the old workstation package intent is preserved, modernized, grouped, and amended from the current laptop inventory;
- official and AUR packages have clear, separate installation paths;
- rerunning the command after a partial failure is safe and expected;
- the repository remains small enough that its behavior can be understood by reading the entry point, focused modules, and package lists without learning a custom framework.
