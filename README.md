# get-arch

`get-arch` is a small Bash configurator for an Arch Linux GNOME workstation. It is intentionally the second stage of installation: `archinstall` owns disks, filesystems, encryption, the bootloader, and the base system; `get-arch` owns workstation configuration from inside the newly installed target and remains rerunnable after first boot.

## 1. Install Arch

From the Arch ISO, start the guided installer with the repository's reusable stage-1 preset:

```bash
archinstall --config-url https://raw.githubusercontent.com/ppanko/get-arch/master/archinstall/get-arch.json
```

The preset supplies only portable workstation policy: the **Minimal** profile, the `linux` kernel, **NetworkManager**, NTP, and Git. It deliberately does not specify disks, partitioning, encryption, bootloader, credentials, hostname, locale, or timezone. Complete those machine-specific choices in the guided installer. Archinstall then installs the base system and runs the pinned `get-arch --install-mode` revision inside the target before the first reboot.

The intended flow is: Arch USB/ISO → guided Archinstall → base system → pinned `get-arch --install-mode` provisioning → one reboot → first GNOME login completes any declared AUR packages → workstation.

The same preset can be used from a local clone with:

```bash
archinstall --config archinstall/get-arch.json
```

Do not replace NetworkManager with another installed-system network manager. `get-arch` deliberately refuses to enable NetworkManager while another manager such as `systemd-networkd`, `dhcpcd` (including per-interface `dhcpcd@...` units), standalone IWD, or ConnMan is active or enabled; it will not attempt a live network-manager handoff underneath the connection being used for installation.

## 2. Inspect the plan

For later maintenance, run the non-destructive check first from the repository retained at `/opt/get-arch`:

```bash
/opt/get-arch/get-arch --check
```

The script prompts for only two installation-specific values:

- username
- hostname

Hardware facts such as laptop/desktop status, GPU vendors, battery presence, boot mode, and network interfaces are detected automatically. `--check` follows the normal configuration path but does not make persistent changes.

## 3. Configure the workstation

```bash
/opt/get-arch/get-arch
```

The default policy configures a complete GNOME workstation, including GNOME/GDM, NetworkManager, PipeWire/WirePlumber, detected graphics support, laptop power support when applicable, SSH, the declared official package groups, and declared AUR packages through `paru`.

Current NVIDIA hardware (Turing and newer) uses the current `nvidia-open` path. Older NVIDIA hardware is not assigned a driver automatically: `get-arch` stops with an actionable message so the appropriate legacy driver can be selected explicitly rather than installing an incompatible current stack.

All package groups are installed by default. The files under `packages/` organize the workstation package set; they are not an interactive installer menu.

For command output while diagnosing a failure:

```bash
./get-arch --verbose
```

If a run stops, fix the underlying error and rerun `./get-arch`. Configuration steps are designed to treat an already-correct state as success; there is no separate checkpoint or rollback database.

A reboot is recommended after a successful first run.

## Archinstall target provisioning

The reusable preset contains an Archinstall `custom_commands` entry that clones
the repository to `/opt/get-arch`, checks out the immutable installation-mode
revision, and invokes:

```bash
/opt/get-arch/get-arch --install-mode
```

Archinstall already runs custom commands inside the target system, so this
command must be invoked directly without another `arch-chroot`. If the target
contains more than one normal login account, select one explicitly:

```bash
./get-arch --install-mode --user pavel
```

Installation mode reads the hostname and existing login accounts created by
Archinstall. It does not create users, change passwords, set the hostname, or
perform the normal full-system upgrade. It installs the official workstation
and hardware packages and enables required services for first boot without
starting them.

Archinstall's `custom_commands` path cannot safely host the interactive
password prompts required by AUR tooling, so `--install-mode` does not build
AUR packages inside the Archinstall chroot. Instead, it stages the AUR build
prerequisites and installs a one-shot continuation for the existing
Archinstall-created user.

On that user's first GNOME login, GNOME Terminal opens automatically and asks
for administrator authentication. The continuation bootstraps `paru`, installs
the exact package set declared in `packages/aur`, and then removes its own
autostart entry. It never asks for a username or hostname and never creates
another account. If AUR completion fails, its pending state is retained and it
retries on the next GNOME login; output is also saved under
`~/.local/state/get-arch/aur-completion.log`. No passwordless sudo policy is
introduced. Normal `./get-arch` mode retains the interactive maintenance path.

For a non-destructive inspection from inside the target chroot, add `--check`:

```bash
/opt/get-arch/get-arch --install-mode --check
```

The custom command is fail-fast. A clone, checkout, or provisioning failure is
reported as an Archinstall failure rather than being ignored.

## Build the custom installer ISO

On an Arch Linux build host, install Archiso and run the unprivileged wrapper:

```bash
sudo pacman -S --needed archiso
./scripts/build-iso
```

The generated ISO is written to `out/` by default. The builder itself does not
use `sudo`, modify `/usr/share/archiso`, select disks, or flash media. It copies
the current official `releng` profile into disposable build state and overlays
the canonical `archinstall/get-arch.json` preset. AUR packages remain deferred
until an interactive session after first boot.

### Smoke-test before flashing

Install the QEMU prerequisites and boot the generated image with Archiso's
`run_archiso` helper:

```bash
sudo pacman -S --needed qemu-desktop edk2-ovmf
run_archiso -u -i out/<generated-iso-name>.iso
```

Confirm all of the following before approving any USB flash:

1. tty1 autologin occurs.
2. With QEMU networking available, Archinstall launches once using `/root/get-arch.json`.
3. Cancelling or exiting Archinstall returns to the live root shell.
4. A new tty1 login shell does not relaunch Archinstall automatically.
5. `archinstall --config /root/get-arch.json` remains available for a deliberate retry.
6. No USB is flashed until this smoke test passes.

The ISO builder never flashes USB media; flashing is a separate, explicitly
confirmed operation outside this workflow.

## Package maintenance

To compare the repository with a current workstation, capture explicitly installed official and foreign packages:

```bash
pacman -Qqen | sort -u > /tmp/get-arch-explicit-packages.txt
pacman -Qqem | sort -u > /tmp/get-arch-foreign-packages.txt
```

Treat these files as review inputs, not repository state. Add only packages that should be reproduced on a normal reinstall; hardware-specific and system-capability packages belong to their modules rather than the package manifests.
