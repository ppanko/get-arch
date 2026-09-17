# Guided Install UX Design

## Goal

Reduce the remaining friction in the custom get-arch installation path without turning it into an unattended installer.

The physical installation test validated the existing architecture. The remaining avoidable work is concentrated in three places:

1. connecting the live environment to Wi-Fi before Archinstall starts;
2. repeating the same known-good disk-layout choices in Archinstall;
3. knowing what account choices to make once Archinstall opens.

This change automates only the disk-layout defaults. Wi-Fi, account creation, encryption, bootloader, locale, timezone, and the final install confirmation remain interactive.

Target flow:

```text
boot custom USB
  -> root autologin on tty1
  -> get-arch launcher checks connectivity
       -> online: continue
       -> offline: guide user through iwctl, then recheck
  -> launcher inspects installation disks
       -> one safe internal candidate: show identity and ask for explicit wipe confirmation
       -> zero/multiple safe candidates: skip disk automation
  -> launcher generates a temporary Archinstall config when disk automation is safe
  -> launch guided Archinstall
       -> validated ext4 best-effort disk layout is already populated when available
       -> account creation remains interactive
       -> encryption remains interactive
       -> bootloader/hostname/locale/timezone remain interactive
       -> user reviews the complete configuration and chooses Install
  -> Archinstall installs the base system
  -> existing pinned get-arch --install-mode provisioning runs in the target
  -> reboot once
  -> GNOME workstation
```

## Scope and design boundary

The launcher remains an orchestration layer around the normal Archinstall guided UI. It must not become a second installer.

The only installation policy moved out of Archinstall's questions is the disk-layout choice already validated on real hardware:

- use Archinstall's best-effort whole-disk layout;
- use ext4 for the main filesystem;
- do not create a separate `/home` partition;
- do not use LVM.

The launcher may prepopulate that layout only after safely resolving and explicitly confirming the target disk. It does not itself partition, format, encrypt, mount, or write the disk.

Encryption remains entirely inside Archinstall. The generated disk configuration must leave disk encryption unset so the user can choose whether and how to encrypt the resulting partitions in the normal Archinstall UI.

Account creation also remains entirely inside Archinstall. get-arch must not collect, generate, persist, hash, or pass user passwords or account credentials.

This design intentionally supersedes the earlier custom-Archiso design's prohibition on disk selection/partition preconfiguration. The earlier requirements that the launcher never directly partition or format a disk, never embed secrets, and preserve Archinstall's final destructive confirmation remain in force.

## Live Wi-Fi guidance

The current launcher performs a bounded connectivity check and, if offline, prints instructions and exits to the shell. The revised launcher should instead keep the user in a guided preflight.

Behavior:

1. Perform the existing bounded connectivity check.
2. If online, continue immediately.
3. If offline, inspect available wireless devices using the live environment's normal iwd tooling.
4. If at least one wireless interface is available, print concise instructions describing the next step and invoke `iwctl` interactively.
5. `iwctl` remains responsible for scanning, SSID selection commands, passphrase entry, and Wi-Fi authentication. get-arch never reads or stores the passphrase.
6. When the user exits `iwctl`, re-run the connectivity check.
7. If connectivity now works, continue automatically to disk preflight.
8. If connectivity is still unavailable, offer a simple retry path or return to the normal recovery shell with the manual Archinstall command.

If no wireless interface is detected, explain that no usable Wi-Fi device was found and return to the recovery shell rather than looping.

The launcher should provide the concrete device name when it can do so reliably, for example:

```text
Wi-Fi is not connected.
Detected wireless device: wlan0

In iwctl:
  station wlan0 scan
  station wlan0 get-networks
  station wlan0 connect "NETWORK NAME"
  exit
```

If more than one wireless device is present, do not guess which one to use. Show the devices and let the user choose inside `iwctl`.

The existing `/run/get-arch-install.started` sentinel remains a guard against login-shell relaunch loops, but the Wi-Fi interaction occurs within the one launcher invocation. A user who successfully connects should therefore proceed directly to Archinstall without needing the current manual relaunch command.

## Safe disk resolution

Disk automation is intentionally fail-closed.

The launcher identifies candidate installation disks from block-device metadata. A disk is eligible for automatic preselection only when all of the following are true:

- it is a whole block device rather than a partition;
- it is not removable;
- it is not the live installer medium or an ancestor of the mounted live filesystem;
- it is not a loop, optical, RAM, mapper, or other virtual/pseudo device;
- it presents as a normal internal storage device suitable for installation;
- exactly one such candidate remains.

The implementation must identify disks by current runtime metadata, not by assuming stable names such as `/dev/sda` or `/dev/nvme0n1`.

When exactly one candidate remains, show at least:

- device path;
- model;
- size;
- transport when available;
- existing partition/filesystem summary when available.

Then require an explicit destructive confirmation tied to the resolved path. A plain yes/no prompt is insufficient. The prompt should require typing a phrase containing the actual device, for example:

```text
Type WIPE /dev/nvme0n1 to preconfigure this disk for erasure:
```

A mismatch cancels disk automation and leaves disk configuration interactive in Archinstall. It must not abort the overall installer unless the user explicitly chooses to exit.

If zero or more than one candidate remains, the launcher must not rank, select, or infer a disk. It should state that disk automation was skipped and allow Archinstall to handle disk selection interactively.

The confirmation step authorizes only prepopulation of Archinstall's wipe layout. No destructive write occurs at that point. Archinstall's own final review and Install confirmation remains the point at which the user authorizes execution.

## Runtime Archinstall disk configuration

Do not hand-maintain a second partitioning algorithm or hard-code partition geometry in get-arch.

When a disk has been safely resolved and confirmed, a small helper should use the Archinstall version shipped in the running ISO to generate Archinstall's own best-effort single-disk layout for that device. For the currently validated Archinstall 4.4 API, the relevant behavior is exposed by `suggest_single_disk_layout()` and accepts both an explicit filesystem type and `separate_home=False`.

The helper should request:

```text
filesystem_type = ext4
separate_home = false
```

and serialize the resulting Archinstall disk configuration through Archinstall's own model serialization. This keeps boot-partition sizing, GPT handling, alignment, object IDs, and future layout details owned by Archinstall rather than duplicated in Bash or static JSON.

The helper writes only a temporary runtime configuration under `/run` or another live-memory location. It then merges or overlays the generated `disk_config` onto the canonical `/root/get-arch.json` preset and launches guided Archinstall with that temporary config.

The canonical repository preset remains machine-independent and does not gain a fixed disk path or partition geometry.

The helper must fail closed if the installed Archinstall API no longer provides the expected layout-generation/serialization contract. In that case:

- print a compatibility warning;
- do not synthesize a replacement layout;
- launch Archinstall with the canonical preset so disk selection remains interactive.

This compatibility behavior is important because custom ISOs are built from the host's current Archiso `releng` profile and therefore may contain newer Archinstall releases over time.

## Account guidance

No account data is automated.

Immediately before Archinstall starts, the launcher should print a short reminder describing the intended account outcome:

```text
In Archinstall, create one normal user and grant it sudo access.
Choose the username, hostname, and password you want for this machine.
```

The user then completes Archinstall's normal account UI. There is no credentials file and no password handling in get-arch.

`get-arch --install-mode` continues to consume the user and hostname Archinstall created rather than creating or modifying identity itself.

## Interactive choices that remain in Archinstall

The user continues to control:

- disk selection and partitioning whenever safe automatic disk resolution is unavailable or declined;
- disk encryption;
- bootloader;
- username and password;
- sudo-capable user creation;
- hostname;
- locale and keyboard settings;
- timezone;
- final configuration review;
- final Install confirmation.

The existing portable preset continues to provide:

- Minimal profile;
- `linux` kernel;
- NetworkManager;
- NTP;
- Git;
- pinned `get-arch --install-mode` provisioning.

## Failure and recovery

Every new convenience must degrade back to the existing guided installer rather than blocking installation.

Wi-Fi failure:
- return to the live shell with useful `iwctl` guidance and the manual Archinstall command if connectivity cannot be established.

Disk detection ambiguity:
- skip disk automation and launch Archinstall with disk configuration unset.

Disk confirmation mismatch or cancellation:
- skip disk automation and leave the decision to Archinstall.

Archinstall API/layout-helper incompatibility:
- skip disk automation, warn clearly, and use the canonical preset.

Archinstall cancellation/failure:
- preserve the existing recovery shell and deliberate manual retry path.

At no point should the launcher attempt to recover from ambiguity by choosing a destructive default.

## Repository shape

Keep the live orchestration code small and separable. The expected shape is:

```text
archiso/
  get-arch-install          # tty1 orchestration, Wi-Fi guidance, user-facing flow
  get-arch-disk-config      # small helper for safe Archinstall disk-config generation
archinstall/
  get-arch.json             # unchanged canonical portable preset
scripts/
  build-iso                 # embeds launcher/helper/preset
 tests/
  test_archiso.sh           # structural and behavioral launcher tests
  ...                       # focused disk-helper tests as needed
```

The exact helper filename may change during implementation, but disk-layout generation should remain isolated from shell UX and network handling.

## Verification

Routine tests must cover at least:

### Wi-Fi flow

- online startup skips Wi-Fi guidance;
- offline startup with one wireless device gives device-specific `iwctl` guidance;
- exiting `iwctl` with connectivity proceeds without requiring a new login shell;
- exiting `iwctl` still offline has a bounded retry/recovery path;
- no Wi-Fi password is accepted, logged, stored, or passed by get-arch;
- no wireless device produces a clear recovery path rather than a loop.

### Disk safety

- the installer USB is excluded;
- removable disks are excluded;
- partitions and pseudo-devices are excluded;
- exactly one eligible internal disk can be proposed;
- zero candidates disables automation;
- multiple candidates disables automation;
- confirmation text includes the actual resolved device path;
- incorrect/missing confirmation performs no disk preconfiguration;
- disk detection never performs a write, partition, format, mount, or wipe itself.

### Disk-layout generation

- a supported Archinstall version generates a default-layout configuration for the selected disk;
- generated root filesystem is ext4;
- generated layout has no separate `/home` partition;
- generated configuration requests a whole-device wipe through Archinstall's normal model;
- LVM is not configured;
- encryption is absent from the generated overlay so the Archinstall encryption UI remains available;
- the canonical preset is not mutated;
- API incompatibility or helper failure falls back to interactive disk configuration.

### Existing boundaries

- the tty1 one-shot guard still works;
- Archinstall final review/install confirmation remains visible and required;
- account configuration remains absent from repository and runtime generated config;
- secrets do not appear in logs or files created by get-arch;
- pinned target provisioning still runs after base installation;
- existing syntax, ShellCheck, test suite, and `./get-arch --check` remain green.

A real ISO smoke test must additionally exercise both paths:

1. one-disk VM: confirm the disk is identified, explicit wipe phrase is required, ext4/no-home layout is prepopulated, encryption remains selectable, account setup remains interactive, and installation reaches target provisioning;
2. ambiguous-disk VM: attach two eligible disks and confirm get-arch refuses to choose between them and Archinstall presents normal disk selection.

A physical smoke test should confirm that the Wi-Fi guidance works with the previously validated USB Wi-Fi adapter and that a successful `iwctl` session proceeds directly into the installer.

## Non-goals

This change does not:

- create a fully unattended installer;
- choose among multiple plausible target disks;
- partition or format disks outside Archinstall;
- silently erase a disk;
- automate disk encryption;
- automate usernames, passwords, or hostname values;
- store Wi-Fi credentials;
- replace `iwctl` or implement a Wi-Fi client;
- introduce LVM, Btrfs, a separate `/home`, or storage profiles;
- add machine profiles or a general installer configuration system;
- remove Archinstall's final review and Install confirmation;
- change the post-install workstation provisioning architecture.
