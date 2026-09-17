# get-arch

`get-arch` is a small Bash post-install configurator for an Arch Linux GNOME workstation. It is intentionally the second stage of installation: `archinstall` owns disks, filesystems, encryption, the bootloader, and the base system; `get-arch` owns workstation configuration after the installed system can boot and reach the network.

## 1. Install Arch

From the Arch ISO, start the guided installer with the repository's reusable stage-1 preset:

```bash
archinstall --config-url https://raw.githubusercontent.com/ppanko/get-arch/master/archinstall/get-arch.json
```

The preset supplies only portable workstation policy: the **Minimal** profile, the `linux` kernel, **NetworkManager**, NTP, and Git. It deliberately does not specify disks, partitioning, encryption, bootloader, credentials, hostname, locale, or timezone. Complete those machine-specific choices in the guided installer, then install and reboot.

The same preset can be used from a local clone with:

```bash
archinstall --config archinstall/get-arch.json
```

Do not replace NetworkManager with another installed-system network manager. `get-arch` deliberately refuses to enable NetworkManager while another manager such as `systemd-networkd`, `dhcpcd` (including per-interface `dhcpcd@...` units), standalone IWD, or ConnMan is active or enabled; it will not attempt a live network-manager handoff underneath the connection being used for installation.

After reboot, log in as root. Git is included by the stage-1 preset, so retrieve the repository:

```bash
git clone https://github.com/ppanko/get-arch.git
cd get-arch
```

If Git is unavailable for any reason, install it first with:

```bash
pacman -Syu --needed git
```

## 2. Inspect the plan

Run the non-destructive check first:

```bash
./get-arch --check
```

The script prompts for only two installation-specific values:

- username
- hostname

Hardware facts such as laptop/desktop status, GPU vendors, battery presence, boot mode, and network interfaces are detected automatically. `--check` follows the normal configuration path but does not make persistent changes.

## 3. Configure the workstation

```bash
./get-arch
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

## Package maintenance

To compare the repository with a current workstation, capture explicitly installed official and foreign packages:

```bash
pacman -Qqen | sort -u > /tmp/get-arch-explicit-packages.txt
pacman -Qqem | sort -u > /tmp/get-arch-foreign-packages.txt
```

Treat these files as review inputs, not repository state. Add only packages that should be reproduced on a normal reinstall; hardware-specific and system-capability packages belong to their modules rather than the package manifests.
