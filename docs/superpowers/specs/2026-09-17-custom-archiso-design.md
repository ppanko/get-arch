# Custom Arch Installer ISO Design

## Goal

Make the normal `get-arch` installation path bootable from a repeatable custom Arch ISO without taking over Archinstall's destructive or machine-specific decisions.

Target flow:

```text
boot custom USB
  -> root autologin on tty1
  -> launcher checks live-network readiness
  -> launch Archinstall once with /root/get-arch.json when online
  -> user chooses disks, partitioning, encryption, bootloader, identity, locale, timezone
  -> Archinstall installs the base system
  -> preset custom_commands runs pinned get-arch --install-mode in the target
  -> Archinstall exits back to the live shell
  -> user reboots once
  -> GNOME workstation
```

If the live environment is not online after a bounded startup wait, the launcher prints concise Wi-Fi guidance and returns to the shell instead of hanging or attempting to manage credentials itself. The user can connect with the normal Arch ISO tooling and then manually run `archinstall --config /root/get-arch.json`.

AUR packages remain deferred until an interactive session after first boot.

## Design choice

Build from the host's current official Archiso `releng` profile rather than vendoring a copy of `releng` into this repository.

The repository stores only the get-arch-specific delta. `scripts/build-iso` copies `/usr/share/archiso/configs/releng` into a temporary build profile, overlays the get-arch files, validates the expected upstream startup hook and required Archinstall package, and invokes `mkarchiso` on the temporary profile.

This keeps the custom media close to the current official Arch ISO while avoiding maintenance of upstream bootloader, package, and profile files. The build is intentionally repeatable rather than bit-for-bit reproducible: it consumes the host's installed Archiso profile and the current Arch package repositories. The build script records the installed Archiso version in its output so the build environment is explicit.

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

`scripts/build-iso` is an Arch-host build command. Current Archiso supports unprivileged builds through user namespaces, so the script must not require root solely to run `mkarchiso`; if the host cannot support an unprivileged Archiso build, `mkarchiso` should fail normally rather than the wrapper forcing privilege escalation.

It will:

1. use `set -euo pipefail`;
2. verify required inputs and commands (`mkarchiso`, the official `releng` profile, the canonical preset, and the launcher);
3. report the installed `archiso` package version used for the build;
4. create disposable work/profile directories rather than modifying `/usr/share/archiso`;
5. install a cleanup `trap` so disposable profile/work state is removed on success, failure, or interruption while preserving the requested output directory and completed ISO;
6. copy the current official `releng` profile into the disposable profile;
7. verify the copied package list still contains `archinstall`; if not, fail clearly before building;
8. copy `archinstall/get-arch.json` to `airootfs/root/get-arch.json`;
9. copy `archiso/get-arch-install` to `airootfs/root/get-arch-install`;
10. verify the copied `airootfs/root/.zlogin` still contains the expected official Archiso startup invocation before patching it;
11. append one guarded invocation of `bash /root/get-arch-install` to the copied `.zlogin`;
12. invoke `mkarchiso` using explicit work and output directories;
13. print the resulting ISO path.

The script must never mutate the installed Archiso profile, choose a USB device, flash media, or invoke privilege escalation such as `sudo` on its own.

## Live launcher

`archiso/get-arch-install` is intentionally small.

It will:

- use `set -euo pipefail`;
- act only on `/dev/tty1`;
- use a sentinel under `/run` to guarantee at most one automatic launch per live boot;
- create the sentinel before any wait or Archinstall invocation, so restarting the login shell cannot create an auto-launch loop;
- perform only a bounded live-network readiness wait;
- confirm usable network connectivity before automatically launching Archinstall;
- when connectivity is unavailable after that bounded wait, print concise instructions to configure Wi-Fi with the normal live-environment tooling (for example `iwctl`) and then manually run `archinstall --config /root/get-arch.json`;
- never request, store, or automate Wi-Fi credentials;
- run `archinstall --config /root/get-arch.json` only when the automatic connectivity check succeeds;
- preserve Archinstall's exit status for the status message;
- return to the normal root shell whether Archinstall succeeds, is cancelled, fails, or automatic launch is skipped for lack of connectivity;
- never restart Archinstall automatically;
- never reboot, power off, partition, format, or select a disk itself.

The launcher must not contain credentials or network secrets. Network readiness logic must be bounded and fail open to the recovery shell rather than waiting indefinitely.

## Upstream integration boundary

The official `releng` profile currently autologs root on tty1. Its root `.zlogin` invokes Archiso's own `.automated_script.sh`. The custom profile preserves that behavior and adds the get-arch launcher after the official startup invocation rather than replacing Archiso's mechanism.

The build script treats the expected `.zlogin` startup line as a compatibility assertion. If upstream Archiso changes that startup path, the build fails clearly instead of silently producing media with uncertain boot behavior.

The build script also treats the presence of `archinstall` in the copied `releng` package list as a compatibility assertion. If upstream `releng` stops including Archinstall, the build fails before `mkarchiso` rather than producing media that cannot satisfy the launcher contract.

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

If automatic launch is skipped because network connectivity is unavailable, the user also lands at the normal live root shell with instructions to connect the live environment and then run:

```bash
archinstall --config /root/get-arch.json
```

The same command is the deliberate retry path after an Archinstall failure.

The preset's provisioning checkout is itself retry-safe: `/opt/get-arch` is cleared and recreated before the pinned revision is checked out.

## Verification

`tests/test_archiso.sh` will perform structural checks without building an ISO in routine CI. It will verify at least:

- the launcher is tty1-only and one-shot;
- the sentinel is created before the connectivity wait and `archinstall` run;
- network readiness has a bounded failure path rather than an indefinite loop;
- lack of connectivity returns to the shell and exposes the manual Archinstall retry command;
- the launcher uses `/root/get-arch.json`;
- the launcher contains no reboot, poweroff, disk-selection, formatting, credential, or Wi-Fi-secret logic;
- the build script copies the canonical preset rather than maintaining a duplicate;
- the build script copies, never mutates, the system `releng` profile;
- the build script asserts that the copied `releng` package set contains `archinstall`;
- the build script validates the upstream `.zlogin` hook before modifying the copied profile;
- the build script reports the Archiso version used;
- the build script installs cleanup handling for disposable build state;
- the build script does not contain USB flashing or privilege-escalation commands;
- the existing Archinstall preset safety tests continue to pass.

CI continues to run Bash syntax checks, ShellCheck, the full existing test suite, and `./get-arch --check`.

A real local verification on an Arch host must additionally:

1. build the ISO successfully with `mkarchiso`;
2. inspect the resulting temporary profile/image contents to confirm the canonical preset and launcher are embedded as intended;
3. boot the resulting ISO in QEMU or an equivalent local VM before any USB is flashed;
4. confirm tty1 autologin automatically starts the launcher exactly once when network connectivity is available;
5. exit or cancel Archinstall and confirm control returns to a normal live root shell;
6. create/re-enter a tty1 login shell and confirm the sentinel prevents automatic relaunch;
7. verify the manual `archinstall --config /root/get-arch.json` retry path remains available.

A successful `mkarchiso` build without this boot-level smoke test is not sufficient for flashing approval.

## USB flashing boundary

Flashing is deliberately outside the build script and outside this implementation PR.

After the ISO has been built, structurally inspected, and passed the VM boot smoke test, the attached USB must be identified by model, size, transport, and removable status. The user must explicitly confirm the target device before any destructive write is performed.

## Non-goals

This change does not:

- automate disk selection or partitioning;
- embed passwords, Wi-Fi credentials, or other secrets;
- manage Wi-Fi authentication automatically;
- add unattended/silent Archinstall operation;
- install AUR packages inside Archinstall;
- vendor the full upstream `releng` profile;
- add automatic USB flashing;
- require root for the ISO build when current Archiso can build unprivileged;
- claim bit-for-bit reproducibility across Archiso/package-repository changes;
- remove the normal standalone/rerunnable `get-arch` workflow.
