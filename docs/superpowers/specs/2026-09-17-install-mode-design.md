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
may set or repair that user's password, performs `pacman -Syu`, and starts SSH.

Install mode is an initial-provisioning path. It:

- accepts `--user USER` only with `--install-mode`;
- otherwise selects the sole existing login account whose UID is within the
  configured normal-user range and whose shell permits login;
- fails rather than guessing when zero or multiple users qualify;
- reads and validates `/etc/hostname` without changing it;
- never creates a user or changes a password;
- may add the selected user to `wheel` and install get-arch's normal wheel
  sudoers policy;
- skips `pacman -Syu` while retaining all normal package and hardware setup;
- reads physical hardware from the API filesystems exposed to the chroot;
- evaluates network-manager conflicts using target unit enablement only;
- enables required units offline for first boot and never starts them;
- does not depend on `/etc/fstab` having been generated.

## AUR provisioning

Install mode performs AUR work before first boot in one PTY-backed session as
the selected user. Root installs the official build prerequisites first. The
user session performs one `sudo -v`, builds paru without root privileges, and
runs paru for the declared AUR packages. No temporary sudo policy or other
privilege bypass is introduced.

## Verification

Focused shell tests cover parsing and mode separation, identity selection and
mutation boundaries, orchestration, services, network conflicts, and AUR
session behavior. The full shell suite, Bash syntax checks, ShellCheck, and a
top-level `./get-arch --check` regression run must pass before opening the PR.
