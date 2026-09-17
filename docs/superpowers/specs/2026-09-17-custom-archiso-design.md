# Custom Arch Installer ISO Design

## Goal

Make the normal `get-arch` installation path bootable from a reproducible custom Arch ISO without taking over Archinstall's destructive or machine-specific decisions.

Target flow:

```text
boot custom USB
  -> root autologin on tty1
  -> launch Archinstall once with /root/get-arch.json
  -> user chooses disks, partitioning, encryption, bootloader, identity, locale, timezone
  -> Archinstall installs the base system
  -> preset custom_commands runs pinned get-arch --install-mode in the target
  -> Archinstall exits back to the live shell
  -> user reboots once
  -> GNOME workstation
```

AUR packages remain deferred until an interactive session after first boot.

## Design choice

Build from the host's current official Archiso `releng` profile rather than vendoring a copy of `releng` into this repository.

The repository stores only the get-arch-specific delta. `scripts/build-iso` copies `/usr/share/archiso/configs/releng` into a temporary build profile, overlays the get-arch files, validates the expected upstream startup hook, and invokes `mkarchiso` on the temporary profile.

This keeps the custom media close to the current official Arch ISO while avoiding maintenance of upstream bootloader, package, and profile files.

## Repository additions

```text
archiso/
  get-arch-install
scripts/
  build-iso
tests/
  test_archiso.sh
docs/superpowers/specs/
  2026-09-17-custom-archiso-design.md
```

The canonical Archinstall preset remains `archinstall/get-arch.json`. The ISO build copies that exact file into the live filesystem as `/root/get-arch.json`; there is no second maintained preset.

## Build script

`scripts/build-iso` is a root-required Arch-host build command.

It will:

1. use `set -euo pipefail`;
2. verify required inputs and commands (`mkarchiso`, the official `releng` profile, the canonical preset, and the launcher);
3. create disposable work/profile directories rather than modifying `/usr/share/archiso`;
4. copy the current official `releng` profile into the disposable profile;
5. copy `archinstall/get-arch.json` to `airootfs/root/get-arch.json`;
6. copy `archiso/get-arch-install` to `airootfs/root/get-arch-install`;
7. verify the copied `airootfs/root/.zlogin` still contains the expected official Archiso startup invocation before patching it;
8. append one guarded invocation of `bash /root/get-arch-install` to the copied `.zlogin`;
9. invoke `mkarchiso` using explicit work and output directories;
10. print the resulting ISO path.

The script must never mutate the installed Archiso profile, choose a USB device, or flash media.

## Live launcher

`archiso/get-arch-install` is intentionally small.

It will:

- use `set -euo pipefail`;
- act only on `/dev/tty1`;
- use a sentinel under `/run` to guarantee at most one automatic launch per live boot;
- create the sentinel before invoking Archinstall;
- run `archinstall --config /root/get-arch.json`;
- preserve Archinstall's exit status for the status message;
- return to the normal root shell whether Archinstall succeeds, is cancelled, or fails;
- never restart Archinstall automatically;
- never reboot, power off, partition, format, or select a disk itself.

The launcher must not contain credentials or network secrets.

## Upstream integration boundary

The official `releng` profile currently autologs root on tty1. Its root `.zlogin` invokes Archiso's own `.automated_script.sh`. The custom profile preserves that behavior and adds the get-arch launcher after the official startup invocation rather than replacing Archiso's mechanism.

The build script treats the expected `.zlogin` startup line as a compatibility assertion. If upstream Archiso changes that startup path, the build fails clearly instead of silently producing media with uncertain boot behavior.

## Archinstall boundary

The embedded preset remains responsible only for portable policy:

- Minimal profile
- `linux` kernel
- NetworkManager
- NTP
- Git
- the pinned, retry-safe `get-arch --install-mode` custom command already merged into the preset

It must continue to omit disks, partitioning, encryption, bootloader configuration, credentials, hostname, locale, and timezone.

The ISO layer does not add defaults for those fields.

## Failure and recovery

If Archinstall exits or fails, the user lands at the normal live root shell. Because the one-shot sentinel has already been created, returning to or recreating the tty1 login shell does not automatically relaunch the installer.

The user may manually run:

```bash
archinstall --config /root/get-arch.json
```

for a deliberate retry.

The preset's provisioning checkout is itself retry-safe: `/opt/get-arch` is cleared and recreated before the pinned revision is checked out.

## Verification

`tests/test_archiso.sh` will perform structural checks without building an ISO in routine CI. It will verify at least:

- the launcher is tty1-only and one-shot;
- the sentinel is created before `archinstall` runs;
- the launcher uses `/root/get-arch.json`;
- the launcher contains no reboot, poweroff, disk-selection, formatting, or credential logic;
- the build script copies the canonical preset rather than maintaining a duplicate;
- the build script copies, never mutates, the system `releng` profile;
- the build script validates the upstream `.zlogin` hook before modifying the copied profile;
- the build script does not contain USB flashing commands;
- the existing Archinstall preset safety tests continue to pass.

CI continues to run Bash syntax checks, ShellCheck, the full existing test suite, and `./get-arch --check`.

A real local verification on an Arch host will additionally build the ISO successfully with `mkarchiso` and inspect the resulting image/profile contents before any USB is flashed.

## USB flashing boundary

Flashing is deliberately outside the build script and outside this implementation PR.

After the ISO has been built and reviewed, the attached USB must be identified by model, size, transport, and removable status. The user must explicitly confirm the target device before any destructive write is performed.

## Non-goals

This change does not:

- automate disk selection or partitioning;
- embed passwords, Wi-Fi credentials, or other secrets;
- add unattended/silent Archinstall operation;
- install AUR packages inside Archinstall;
- vendor the full upstream `releng` profile;
- add automatic USB flashing;
- remove the normal standalone/rerunnable `get-arch` workflow.
