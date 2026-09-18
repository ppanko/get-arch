# Guided Install UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the custom Archiso guide Wi-Fi setup, safely prepopulate the validated single-disk ext4 layout, and leave account creation and encryption interactive in Archinstall.

**Architecture:** Keep `archiso/get-arch-install` as the tty1 orchestration layer. Add an isolated Python helper, `archiso/get-arch-disk-config`, that asks the running Archinstall library to generate its own single-disk best-effort layout and merges that `disk_config` into a temporary copy of the canonical preset. The launcher detects safe disk candidates with `lsblk`, requires an explicit `WIPE <device>` confirmation, falls back to normal guided Archinstall on ambiguity or helper failure, and uses `iwctl` only as an interactive Wi-Fi assistant.

**Tech Stack:** Bash, Python 3, Archinstall 4.4+ runtime API, Archiso releng, GitHub Actions on `archlinux:latest`.

**Spec:** `docs/superpowers/specs/2026-09-17-guided-install-ux-design.md`

## Global Constraints

- Only disk-layout defaults are automated. The preset seeds `America/New_York` as the timezone default, but timezone selection remains editable; Wi-Fi, account creation, encryption, bootloader, locale, and final install confirmation remain interactive.
- Disk policy is Archinstall best-effort whole-disk layout, ext4, no separate `/home`, no LVM.
- Never auto-select USB-transport disks, removable devices, partitions, loop/optical/RAM/mapper/pseudo devices, or the live installer medium.
- Never rank or guess among multiple eligible disks.
- Disk confirmation must require the literal phrase `WIPE <resolved-device-path>`.
- The launcher/helper must never directly partition, format, wipe, mount, encrypt, or reboot.
- Archinstall remains responsible for final destructive execution and its final Install confirmation.
- No Wi-Fi or account credentials may be collected, stored, logged, or embedded by get-arch.
- Any disk-detection or Archinstall-API uncertainty falls back to normal interactive Archinstall.
- The canonical `archinstall/get-arch.json` remains free of disk- and identity-specific values and is never mutated at runtime; its `America/New_York` timezone value is an editable default.

---

### Task 1: Add failing guided-install structural tests

**Files:**
- Modify: `tests/test_archiso.sh`

**Interfaces:**
- Consumes: current launcher `archiso/get-arch-install` and builder `scripts/build-iso`.
- Produces: regression assertions for the new helper, Wi-Fi flow, disk safety, runtime preset path, and builder embedding.

- [ ] **Step 1: Extend `tests/test_archiso.sh` with failing assertions**

Add assertions that require:

```python
helper = Path('archiso/get-arch-disk-config')
assert helper.is_file()
helper_text = helper.read_text(encoding='utf-8')
assert helper_text.startswith('#!/usr/bin/env python3\n')
assert 'suggest_single_disk_layout' in helper_text
assert 'FilesystemType.EXT4' in helper_text
assert 'separate_home=False' in helper_text
assert "'disk_config'" in helper_text or '"disk_config"' in helper_text
assert '/run/get-arch.json' in launcher_text
assert 'lsblk' in launcher_text
assert 'WIPE ' in launcher_text
assert 'TRAN' in launcher_text
assert 'RM' in launcher_text
assert 'iwctl' in launcher_text
assert 'create one normal user' in launcher_text.lower()
```

Update the builder assertions to require copying the helper into `airootfs/root/get-arch-disk-config` before `.zlogin` is patched.

Keep the existing forbidden-command assertions and extend them so neither live script contains `mkfs`, `wipefs`, `fdisk`, `parted`, `cryptsetup`, `mount `, `reboot`, or `poweroff`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
bash tests/test_archiso.sh
```

Expected: FAIL because `archiso/get-arch-disk-config` does not yet exist and the launcher does not contain the new guided-install behavior.

- [ ] **Step 3: Commit the failing tests**

```bash
git add tests/test_archiso.sh
git commit -m "test: define guided install UX behavior"
```

---

### Task 2: Add Archinstall-owned disk-config generation

**Files:**
- Create: `archiso/get-arch-disk-config`
- Create: `tests/test_disk_config.py`

**Interfaces:**
- Consumes: CLI arguments `--device PATH`, `--base-config PATH`, `--output PATH`; runtime Archinstall modules `device_handler`, `suggest_single_disk_layout`, `DiskLayoutConfiguration`, `DiskLayoutType`, and `FilesystemType`.
- Produces: exit status 0 and a merged JSON config at `--output`; nonzero status with no usable output on API/device/generation failure.

- [ ] **Step 1: Write a failing helper test with a fake Archinstall module graph**

Create `tests/test_disk_config.py` that loads the helper as a module with `runpy`/`importlib`, injects fake `archinstall.lib.disk.device_handler`, `archinstall.lib.disk.disk_menu`, and `archinstall.lib.models.device` modules in `sys.modules`, and verifies the helper's callable core passes `FilesystemType.EXT4` and `separate_home=False` to `suggest_single_disk_layout`, creates `DiskLayoutConfiguration(DiskLayoutType.Default, [modification])`, and merges only `disk_config` into a base mapping.

The fake configuration object should expose:

```python
class FakeDiskLayoutConfiguration:
    def __init__(self, config_type, device_modifications):
        self.config_type = config_type
        self.device_modifications = device_modifications

    def json(self):
        return {
            'config_type': 'default',
            'device_modifications': [m.json() for m in self.device_modifications],
        }
```

Assert that unrelated base keys such as `kernels`, `network_config`, `custom_commands`, and the `America/New_York` timezone default survive unchanged and that no encryption or LVM key is introduced by the helper.

- [ ] **Step 2: Run the helper test and verify RED**

Run:

```bash
python tests/test_disk_config.py
```

Expected: FAIL because `archiso/get-arch-disk-config` does not exist.

- [ ] **Step 3: Implement the minimal helper**

Create `archiso/get-arch-disk-config` with:

```python
#!/usr/bin/env python3
import argparse
import asyncio
import json
from pathlib import Path


def generate_disk_config(device_path: Path) -> dict:
    from archinstall.lib.disk.device_handler import device_handler
    from archinstall.lib.disk.disk_menu import suggest_single_disk_layout
    from archinstall.lib.models.device import DiskLayoutConfiguration, DiskLayoutType, FilesystemType

    device = device_handler.get_device(device_path)
    if device is None:
        raise RuntimeError(f'Archinstall cannot resolve device: {device_path}')

    modification = asyncio.run(
        suggest_single_disk_layout(
            device,
            filesystem_type=FilesystemType.EXT4,
            separate_home=False,
        )
    )
    config = DiskLayoutConfiguration(
        config_type=DiskLayoutType.Default,
        device_modifications=[modification],
    )
    return config.json()


def merge_config(base: dict, disk_config: dict) -> dict:
    merged = dict(base)
    merged['disk_config'] = disk_config
    return merged
```

`main()` parses the three required paths, loads the canonical base JSON, generates the disk config, writes the merged JSON atomically via a sibling temporary file plus `Path.replace()`, and returns nonzero with a concise `get-arch disk config:` error on any exception. It must never import or create `DiskEncryption` or `LvmConfiguration`.

- [ ] **Step 4: Run the helper test and verify GREEN**

Run:

```bash
python tests/test_disk_config.py
python -m py_compile archiso/get-arch-disk-config
```

Expected: PASS.

- [ ] **Step 5: Commit the helper**

```bash
git add archiso/get-arch-disk-config tests/test_disk_config.py
git commit -m "feat: generate Archinstall disk config safely"
```

---

### Task 3: Implement guided Wi-Fi and fail-closed disk selection in the launcher

**Files:**
- Modify: `archiso/get-arch-install`
- Create: `tests/test_archiso_runtime.sh`

**Interfaces:**
- Consumes: `curl`, `iwctl`, `lsblk`, `/run/archiso/bootmnt`/live mount metadata where available, `/root/get-arch.json`, `/root/get-arch-disk-config`.
- Produces: selected runtime config path (`/root/get-arch.json` or `/run/get-arch.json`) passed to `archinstall --config`.

- [ ] **Step 1: Write failing launcher runtime tests with command shims**

Create `tests/test_archiso_runtime.sh`. For each case, create a temporary `PATH` containing fake `tty`, `curl`, `iwctl`, `lsblk`, `findmnt`, `readlink`, `archinstall`, and disk-helper commands, then execute the launcher with an isolated sentinel path by copying the script and replacing `/run/get-arch-install.started` and `/run/get-arch.json` with temporary paths.

Cover these concrete behaviors:

1. online startup does not invoke `iwctl`;
2. offline startup invokes interactive `iwctl`, then a successful second connectivity probe continues to Archinstall;
3. one `lsblk` candidate with `TYPE=disk`, `RM=0`, and `TRAN=nvme` is proposed;
4. `TRAN=usb` is never proposed even when `RM=0`;
5. `RM=1` is never proposed;
6. two eligible internal disks result in no helper call and canonical preset use;
7. confirmation mismatch results in no helper call and canonical preset use;
8. exact `WIPE /dev/nvme0n1` confirmation calls `/root/get-arch-disk-config --device /dev/nvme0n1 --base-config /root/get-arch.json --output /run/get-arch.json` and then launches Archinstall with `/run/get-arch.json`;
9. helper failure falls back to `/root/get-arch.json`;
10. launcher output reminds the user to create one normal sudo-capable user in Archinstall.

- [ ] **Step 2: Run runtime tests and verify RED**

Run:

```bash
bash tests/test_archiso_runtime.sh
```

Expected: FAIL because the launcher still has the old bounded-network-only flow and no disk preflight.

- [ ] **Step 3: Implement network helper functions**

Refactor the launcher into small functions while retaining `set -euo pipefail` and the tty1/sentinel guard:

```bash
network_ready() { ... }          # bounded curl probe
wireless_devices() { ... }       # iwctl device list parsing or equivalent iwd-readable source
ensure_network() { ... }         # print guidance, run iwctl interactively, recheck
manual_retry() { ... }
```

`ensure_network` must never read a passphrase itself. If offline, print detected wireless device names when reliable, invoke `iwctl`, and recheck. If still offline, return nonzero so the launcher prints the recovery command and exits to the shell.

- [ ] **Step 4: Implement disk candidate resolution and confirmation**

Add functions:

```bash
list_disk_candidates() { ... }
confirm_disk() { ... }
prepare_runtime_config() { ... }
```

Use one machine-readable `lsblk` call such as:

```bash
lsblk -dnP -o NAME,PATH,TYPE,RM,TRAN,SIZE,MODEL,MOUNTPOINTS
```

Accept only rows where `TYPE="disk"`, `RM="0"`, and `TRAN` is not `usb`; reject empty/pseudo device classes. Determine the live medium from mounted live-environment metadata (`findmnt`/`readlink`) when available and exclude its parent disk. If live-medium resolution is uncertain, do not relax the other filters or guess.

If the final candidate count is not exactly one, print that disk automation is skipped and return the canonical preset path.

If exactly one remains, print path/model/size/transport and existing child summary via `lsblk "$device"`, then read one line and compare exactly with `WIPE $device`. Mismatch means interactive fallback, not installer abort.

- [ ] **Step 5: Generate the runtime config only after confirmation**

On exact confirmation, invoke:

```bash
/root/get-arch-disk-config \
  --device "$device" \
  --base-config /root/get-arch.json \
  --output /run/get-arch.json
```

If and only if that command succeeds and `/run/get-arch.json` is a nonempty file, return `/run/get-arch.json`; otherwise warn and return `/root/get-arch.json`.

Immediately before Archinstall, print:

```text
In Archinstall, create one normal user and grant it sudo access.
Choose the username, hostname, and password you want for this machine.
Encryption remains your choice in Archinstall.
```

Then run `archinstall --config "$config_path"`.

- [ ] **Step 6: Run runtime and structural tests and verify GREEN**

Run:

```bash
bash tests/test_archiso_runtime.sh
bash tests/test_archiso.sh
bash -n archiso/get-arch-install tests/test_archiso_runtime.sh
```

Expected: PASS.

- [ ] **Step 7: Commit the launcher changes**

```bash
git add archiso/get-arch-install tests/test_archiso_runtime.sh tests/test_archiso.sh
git commit -m "feat: guide live install preflight"
```

---

### Task 4: Embed the disk helper in custom Archiso and CI

**Files:**
- Modify: `scripts/build-iso`
- Modify: `.github/workflows/test.yml`
- Modify: `tests/test_archiso.sh`

**Interfaces:**
- Consumes: `archiso/get-arch-disk-config` from Task 2.
- Produces: `/root/get-arch-disk-config` in the live ISO and syntax/test coverage for the Python helper.

- [ ] **Step 1: Add failing builder assertions before modifying the builder**

Require `scripts/build-iso` to define a helper path, validate it exists, and copy it after the launcher:

```bash
readonly DISK_HELPER="$repo_root/archiso/get-arch-disk-config"
[[ -f $DISK_HELPER ]] || fail "missing disk helper: $DISK_HELPER"
cp -- "$DISK_HELPER" "$profile_dir/airootfs/root/get-arch-disk-config"
```

Assert copy order is profile -> preset -> launcher/helper -> `.zlogin` patch.

- [ ] **Step 2: Run `bash tests/test_archiso.sh` and verify RED**

Expected: FAIL because the builder does not yet embed the helper.

- [ ] **Step 3: Update `scripts/build-iso` minimally**

Add `DISK_HELPER`, validate it, and copy it into `airootfs/root`. Keep all existing safety properties: no sudo, no USB writes, no system-releng mutation, and cleanup via user namespace when non-root.

- [ ] **Step 4: Update CI checks**

Extend syntax/compile validation so CI runs:

```yaml
- name: Check Bash syntax
  run: bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
- name: Check Python syntax
  run: python -m py_compile archiso/get-arch-disk-config tests/test_disk_config.py
```

Do not add a production Python dependency beyond Python already present in the releng environment; Archinstall itself is the runtime dependency.

- [ ] **Step 5: Run focused verification and commit**

Run:

```bash
bash tests/test_archiso.sh
python tests/test_disk_config.py
bash tests/test_archiso_runtime.sh
```

Then:

```bash
git add scripts/build-iso .github/workflows/test.yml tests/test_archiso.sh
git commit -m "build: embed guided install disk helper"
```

---

### Task 5: Document the revised physical-install flow

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: completed launcher behavior from Tasks 2-4.
- Produces: operator-facing instructions matching the custom ISO.

- [ ] **Step 1: Add/update the custom ISO workflow section**

Document the flow exactly:

```text
boot USB
-> connect Wi-Fi through guided iwctl when needed
-> confirm the one safe internal disk if automatic preselection is offered
-> Archinstall opens with ext4/no-home/no-LVM layout prepopulated when safe
-> choose encryption interactively
-> keep or change the prefilled America/New_York timezone
-> create one normal sudo-capable user, hostname, and password interactively
-> review and choose Install
-> get-arch provisions the workstation
-> reboot
```

State explicitly that multiple disks, USB storage, uncertain disk detection, declined confirmation, or helper incompatibility leave disk selection fully interactive.

- [ ] **Step 2: Verify README does not imply unattended installation or stored credentials**

Run:

```bash
grep -nE 'unattended|password|Wi-Fi|disk|encryption' README.md
```

Review the matching paragraphs to ensure passwords remain interactive and final erase/install authorization remains in Archinstall.

- [ ] **Step 3: Commit documentation**

```bash
git add README.md
git commit -m "docs: describe guided custom ISO flow"
```

---

### Task 6: Full verification and PR

**Files:**
- Verify all changed files.

**Interfaces:**
- Produces: a reviewable feature branch and pull request.

- [ ] **Step 1: Run syntax/static checks**

```bash
bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
python -m py_compile archiso/get-arch-disk-config tests/test_disk_config.py
shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
```

Expected: zero errors.

- [ ] **Step 2: Run the entire repository test suite**

```bash
./tests/run
```

Expected: all tests pass.

- [ ] **Step 3: Exercise full check mode**

```bash
printf 'ciuser\nci-host\n' | ./get-arch --check
```

Expected: exit 0.

- [ ] **Step 4: Review the diff against the approved spec**

Confirm every failure path degrades to interactive Archinstall, no credentials are added, the runtime disk overlay preserves the canonical preset's timezone/default policy, and no live script contains a direct destructive disk command.

- [ ] **Step 5: Open a pull request**

Create a PR from `feature/guided-install-ux` to `master` summarizing:

- guided live Wi-Fi using interactive `iwctl`;
- fail-closed internal-disk detection and typed confirmation;
- Archinstall-owned ext4/no-home/no-LVM runtime disk layout generation;
- account and encryption remaining interactive;
- helper/build/test coverage;
- local verification results and any environment limitation (for example, no real `mkarchiso`/QEMU smoke test in the current execution environment).
