# get-arch Install Mode Design

## Goal

Add an explicit `--install-mode` that Archinstall can invoke through its
`custom_commands` mechanism after installing the base system. Archinstall
already executes those commands inside the target with `arch-chroot`, so
get-arch must configure the current root directly and must not invoke another
chroot.

## Mode boundaries

Normal mode remains the interactive, rerunnable workstation-maintenance path.
It continues to prompt for username and hostname, may create a missing user,
may set or repair that user's password, performs `pacman -Syu`, starts SSH, and
retains the existing interactive AUR workflow.

Install mode is an initial-provisioning path. It:

- accepts `--user USER` only with `--install-mode`;
- otherwise selects the sole existing login account whose UID is within the
  configured normal-user range and whose shell permits login;
- fails rather than guessing when zero or multiple users qualify;
- reads and validates `/etc/hostname` without changing it;
- never creates a user or changes a password;
- may add the selected user to `wheel` and install get-arch's normal wheel
  sudoers policy;
- skips `pacman -Syu` while retaining all normal official package and hardware
  setup;
- reads physical hardware from the API filesystems exposed to the chroot;
- evaluates network-manager conflicts using target unit enablement only;
- enables required units offline for first boot and never starts them;
- does not depend on `/etc/fstab` having been generated;
- remains noninteractive when invoked through Archinstall `custom_commands`.

## AUR provisioning

AUR work is deferred in install mode. Archinstall 4.4's `custom_commands`
execution path does not provide a usable interactive stdin channel for a sudo
password prompt, so install mode must not enter a target-user PTY session or
run `sudo`, `makepkg`, or `paru`. It loads the declared AUR package list and
logs which packages are deferred until after first boot. No temporary
passwordless sudo policy or other privilege bypass is introduced.

Normal mode keeps the existing interactive AUR behavior. A later first-boot or
custom-USB completion step may install the deferred AUR packages with a real
interactive terminal, but that is outside this install-mode change.

## Verification

Focused shell tests cover parsing and mode separation, identity selection and
mutation boundaries, orchestration, services, network conflicts, and the
noninteractive AUR deferral boundary. The full shell suite, Bash syntax checks,
ShellCheck, and top-level normal/install check regressions must pass before
merge.
