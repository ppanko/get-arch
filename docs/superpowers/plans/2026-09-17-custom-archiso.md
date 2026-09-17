# Custom Archiso Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repeatable custom Arch installer ISO that starts the existing guided Archinstall preset once on tty1, provisions the target through the pinned `get-arch --install-mode` hook, and always preserves a recovery shell without automating destructive choices.

**Architecture:** Keep the repository delta small. A live launcher owns one-shot tty1/network/startup behavior, while `scripts/build-iso` copies the host's current official `releng` profile into disposable state, overlays the canonical preset and launcher, validates upstream assumptions, then calls `mkarchiso`. Routine CI is structural; a real Arch-host ISO build and QEMU boot smoke test are mandatory before flashing.

**Tech Stack:** Bash, Arch Linux `archiso`/`mkarchiso`, Archinstall, Python 3 for structural assertions, ShellCheck, QEMU via `run_archiso`.

**Spec:** `docs/superpowers/specs/2026-09-17-custom-archiso-design.md`

## Global Constraints

- The canonical preset is `archinstall/get-arch.json`; do not create a second maintained preset.
- The ISO layer must never select disks, partition, format, configure encryption, choose a bootloader, set credentials, set hostname/locale/timezone, or flash USB media.
- The launcher acts only on `/dev/tty1`, launches automatically at most once per live boot, and returns to a normal root shell on success, cancellation, failure, or lack of network.
- Network readiness must be bounded; no infinite wait and no Wi-Fi credential handling.
- Preserve the official `releng` `.zlogin` automated-script behavior and fail closed if the expected upstream hook changes.
- Fail before building if the copied `releng` package list no longer contains `archinstall`.
- Do not vendor the full upstream `releng` profile.
- Do not require root solely for `mkarchiso`; current Archiso supports unprivileged builds through user namespaces.
- Do not invoke `sudo` or other privilege escalation from `scripts/build-iso`.
- A successful ISO build alone is not enough for flashing approval; the ISO must pass the documented QEMU smoke test first.
- AUR packages remain deferred until the interactive first-boot session.

---

### Task 1: Add the one-shot live installer launcher

**Files:**
- Create: `archiso/get-arch-install`
- Create: `tests/test_archiso.sh`

**Interfaces:**
- Consumes: `/root/get-arch.json`, `/dev/tty1`, `/run`, `curl`, and `archinstall` in the live ISO.
- Produces: `archiso/get-arch-install`, invoked later by the copied `releng` `.zlogin` as `bash /root/get-arch-install`.

- [ ] **Step 1: Write the failing structural test for launcher safety and ordering**

Create `tests/test_archiso.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

launcher=archiso/get-arch-install

if [[ ! -f $launcher ]]; then
  printf 'FAIL: missing Archiso launcher: %s\n' "$launcher" >&2
  exit 1
fi

python - "$launcher" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')

assert text.startswith('#!/usr/bin/env bash\nset -euo pipefail\n'), text[:80]
assert '/dev/tty1' in text
assert '/run/get-arch-install.started' in text
assert '/root/get-arch.json' in text
assert 'archinstall --config "$PRESET"' in text
assert 'iwctl' in text
assert 'curl ' in text
assert 'for attempt in 1 2 3 4 5' in text

sentinel = ': > "$SENTINEL"'
probe = 'for attempt in 1 2 3 4 5'
install = 'archinstall --config "$PRESET"'
assert text.index(sentinel) < text.index(probe) < text.index(install)

manual = 'archinstall --config /root/get-arch.json'
assert text.count(manual) >= 1

for forbidden in (
    'reboot',
    'poweroff',
    'shutdown',
    'mkfs',
    'fdisk',
    'parted',
    'wipefs',
    'dd if=',
    'sudo ',
    'wpa_passphrase',
):
    assert forbidden not in text, forbidden
PY
```

- [ ] **Step 2: Run the new test and verify it fails before implementation**

Run:

```bash
bash tests/test_archiso.sh
```

Expected: `FAIL: missing Archiso launcher: archiso/get-arch-install`.

- [ ] **Step 3: Implement the minimal launcher**

Create `archiso/get-arch-install`:

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly SENTINEL=/run/get-arch-install.started
readonly PRESET=/root/get-arch.json

manual_retry() {
  printf '\nConnect the live environment if needed. For Wi-Fi, use: iwctl\n'
  printf 'Then start the installer manually with:\n'
  printf '  archinstall --config /root/get-arch.json\n'
}

if [[ $(tty) != /dev/tty1 ]]; then
  exit 0
fi

if [[ -e $SENTINEL ]]; then
  exit 0
fi

: > "$SENTINEL"

if ! command -v archinstall >/dev/null 2>&1; then
  printf 'get-arch installer: archinstall is unavailable in this live environment.\n' >&2
  manual_retry
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  printf 'get-arch installer: curl is unavailable; automatic network readiness cannot be checked.\n' >&2
  manual_retry
  exit 0
fi

online=false
for attempt in 1 2 3 4 5; do
  if curl --silent --fail --head --connect-timeout 2 --max-time 3 https://archlinux.org/ >/dev/null; then
    online=true
    break
  fi
  sleep 1
done

if [[ $online != true ]]; then
  printf 'get-arch installer: network connectivity is not ready; automatic launch skipped.\n'
  manual_retry
  exit 0
fi

printf 'get-arch installer: starting guided Archinstall.\n'
if archinstall --config "$PRESET"; then
  printf 'get-arch installer: Archinstall exited successfully.\n'
else
  status=$?
  printf 'get-arch installer: Archinstall exited with status %d.\n' "$status" >&2
  manual_retry
fi
```

The non-zero Archinstall status is captured for the message but intentionally not re-emitted as the launcher exit status; the login shell must remain usable.

- [ ] **Step 4: Run syntax, ShellCheck, and the launcher structural test**

Run:

```bash
bash -n archiso/get-arch-install tests/test_archiso.sh
shellcheck archiso/get-arch-install tests/test_archiso.sh
bash tests/test_archiso.sh
```

Expected: all commands exit 0.

- [ ] **Step 5: Commit the launcher task**

```bash
git add archiso/get-arch-install tests/test_archiso.sh
git commit -m "Add one-shot Archiso installer launcher"
```

---

### Task 2: Add the safe `releng` profile builder

**Files:**
- Create: `scripts/build-iso`
- Modify: `tests/test_archiso.sh`

**Interfaces:**
- Consumes: `/usr/share/archiso/configs/releng`, `archinstall/get-arch.json`, `archiso/get-arch-install`, `mkarchiso`, and `pacman`.
- Produces: exactly one completed `.iso` in an optional output directory argument, defaulting to `out/` under the repository root.

- [ ] **Step 1: Extend the structural test before creating the builder**

Append to `tests/test_archiso.sh`:

```bash
builder=scripts/build-iso

if [[ ! -f $builder ]]; then
  printf 'FAIL: missing Archiso build script: %s\n' "$builder" >&2
  exit 1
fi

python - "$builder" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')

assert text.startswith('#!/usr/bin/env bash\nset -euo pipefail\n'), text[:80]
assert '/usr/share/archiso/configs/releng' in text
assert 'archinstall/get-arch.json' in text
assert 'archiso/get-arch-install' in text
assert 'pacman -Q archiso' in text
assert "grep -Fxq 'archinstall'" in text
assert "grep -Fxc '~/.automated_script.sh'" in text
assert 'bash /root/get-arch-install' in text
assert 'mkarchiso -v -w "$work_dir" -o "$build_output" "$profile_dir"' in text
assert 'trap cleanup EXIT HUP INT TERM' in text

copy_profile = 'cp -a -- "$RELENG_DIR" "$profile_dir"'
copy_preset = 'cp -- "$PRESET" "$profile_dir/airootfs/root/get-arch.json"'
patch_zlogin = "printf '\\nbash /root/get-arch-install\\n' >> \"$zlogin\""
assert text.index(copy_profile) < text.index(copy_preset) < text.index(patch_zlogin)

for forbidden in (
    'dd if=',
    'wipefs',
    'mkfs',
    '/dev/sd',
    '/dev/nvme',
    'sudo ',
):
    assert forbidden not in text, forbidden
PY
```

- [ ] **Step 2: Run the test and verify the builder assertion fails**

Run:

```bash
bash tests/test_archiso.sh
```

Expected: `FAIL: missing Archiso build script: scripts/build-iso`.

- [ ] **Step 3: Implement the build wrapper**

Create `scripts/build-iso`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
readonly RELENG_DIR=/usr/share/archiso/configs/releng
readonly PRESET="$repo_root/archinstall/get-arch.json"
readonly LAUNCHER="$repo_root/archiso/get-arch-install"
output_dir=${1:-"$repo_root/out"}

fail() {
  printf 'get-arch ISO build: %s\n' "$*" >&2
  exit 1
}

for command in mkarchiso pacman; do
  command -v "$command" >/dev/null 2>&1 || fail "missing required command: $command"
done

[[ -d $RELENG_DIR ]] || fail "missing official releng profile: $RELENG_DIR"
[[ -f $PRESET ]] || fail "missing canonical preset: $PRESET"
[[ -f $LAUNCHER ]] || fail "missing live launcher: $LAUNCHER"

archiso_version=$(pacman -Q archiso 2>/dev/null) || fail 'archiso package is not installed'
printf 'get-arch ISO build: using %s\n' "$archiso_version"

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/get-arch-iso.XXXXXX")
readonly tmp_root
profile_dir="$tmp_root/profile"
work_dir="$tmp_root/work"
build_output="$tmp_root/output"

cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT HUP INT TERM

cp -a -- "$RELENG_DIR" "$profile_dir"

packages="$profile_dir/packages.x86_64"
[[ -f $packages ]] || fail "copied releng profile has no packages.x86_64"
grep -Fxq 'archinstall' "$packages" || fail 'copied releng profile no longer includes archinstall'

mkdir -p "$profile_dir/airootfs/root"
cp -- "$PRESET" "$profile_dir/airootfs/root/get-arch.json"
cp -- "$LAUNCHER" "$profile_dir/airootfs/root/get-arch-install"

zlogin="$profile_dir/airootfs/root/.zlogin"
[[ -f $zlogin ]] || fail 'copied releng profile has no root .zlogin'
startup_count=$(grep -Fxc '~/.automated_script.sh' "$zlogin" || true)
[[ $startup_count -eq 1 ]] || fail 'unexpected releng .zlogin startup hook; refusing to patch'
if grep -Fq 'get-arch-install' "$zlogin"; then
  fail 'copied releng .zlogin already references get-arch-install'
fi
printf '\nbash /root/get-arch-install\n' >> "$zlogin"

mkdir -p "$work_dir" "$build_output" "$output_dir"
mkarchiso -v -w "$work_dir" -o "$build_output" "$profile_dir"

mapfile -t images < <(find "$build_output" -maxdepth 1 -type f -name '*.iso' -print)
[[ ${#images[@]} -eq 1 ]] || fail "expected exactly one ISO, found ${#images[@]}"

final_iso="$output_dir/$(basename "${images[0]}")"
mv -- "${images[0]}" "$final_iso"
printf 'get-arch ISO build: %s\n' "$final_iso"
```

This intentionally lets `mkarchiso` decide whether the host's user-namespace support is sufficient; the wrapper never elevates itself.

- [ ] **Step 4: Run structural and shell verification**

Run:

```bash
bash -n scripts/build-iso tests/test_archiso.sh
shellcheck scripts/build-iso tests/test_archiso.sh
bash tests/test_archiso.sh
```

Expected: all commands exit 0.

- [ ] **Step 5: Run the full repository test suite**

Run:

```bash
./tests/run
./get-arch --check <<'EOF'
ciuser
ci-host
EOF
```

Expected: all tests pass and check mode exits 0.

- [ ] **Step 6: Commit the builder task**

```bash
git add scripts/build-iso tests/test_archiso.sh
git commit -m "Add safe custom Archiso builder"
```

---

### Task 3: Wire CI and document the build/test workflow

**Files:**
- Modify: `.github/workflows/test.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: the launcher and builder from Tasks 1-2.
- Produces: CI coverage for both no-extension Bash scripts and user-facing commands for building and smoke-testing the ISO.

- [ ] **Step 1: Update CI syntax and ShellCheck inputs**

Change the two workflow commands to:

```yaml
      - name: Check Bash syntax
        run: bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
      - name: Run ShellCheck
        run: shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
```

Do not add a full `mkarchiso` build to routine CI.

- [ ] **Step 2: Add concise README instructions for custom media**

Add a `## Build the custom installer ISO` section containing these commands and boundaries:

```bash
sudo pacman -S --needed archiso
./scripts/build-iso
```

Document that the default output is `out/`, the builder does not use `sudo`, modify `/usr/share/archiso`, select disks, or flash media, and that AUR packages remain deferred until after first boot.

Add a `### Smoke-test before flashing` subsection:

```bash
sudo pacman -S --needed qemu-desktop edk2-ovmf
run_archiso -u -i out/<generated-iso-name>.iso
```

State the required observations exactly:

1. tty1 autologin occurs;
2. with QEMU networking available, Archinstall launches once using `/root/get-arch.json`;
3. cancelling/exiting Archinstall returns to the live root shell;
4. a new tty1 login shell does not relaunch Archinstall automatically;
5. `archinstall --config /root/get-arch.json` remains available for a deliberate retry;
6. no USB should be flashed until this smoke test passes.

Current Arch packages provide `qemu-desktop` and `edk2-ovmf`; `run_archiso` is supplied by Archiso.

- [ ] **Step 3: Run all static and repository verification**

Run:

```bash
bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
./tests/run
printf 'ciuser\nci-host\n' | ./get-arch --check
```

Expected: all commands exit 0.

- [ ] **Step 4: Commit CI and documentation**

```bash
git add .github/workflows/test.yml README.md
git commit -m "Document custom Archiso build and smoke test"
```

---

### Task 4: Perform the real Arch-host build and pre-flash smoke gate

**Files:**
- No source file changes required unless verification reveals a defect.
- Generated artifact: `out/*.iso` (must remain uncommitted).

**Interfaces:**
- Consumes: completed Tasks 1-3 on an Arch Linux host.
- Produces: evidence that the ISO builds, contains the canonical preset/launcher, boots, launches once, and recovers to a shell. This is the prerequisite for opening/merging the implementation PR and for any later USB flash request.

- [ ] **Step 1: Install local build and VM prerequisites**

Run on the Arch host:

```bash
sudo pacman -S --needed archiso qemu-desktop edk2-ovmf
```

Expected: `mkarchiso` and `run_archiso` are available.

- [ ] **Step 2: Build without privilege escalation**

Run from the repository root:

```bash
./scripts/build-iso
```

Expected: the script prints the installed Archiso version, completes successfully, and prints one final path under `out/`.

Do not retry with `sudo ./scripts/build-iso` merely to bypass a failure. If unprivileged `mkarchiso` fails because user namespaces are unavailable, record the actual error and fix/decide that host constraint explicitly.

- [ ] **Step 3: Inspect the built root filesystem for the exact embedded files**

Set the ISO path printed by the builder, then run:

```bash
iso=out/<generated-iso-name>.iso
inspect_dir=$(mktemp -d)
bsdtar -xf "$iso" -C "$inspect_dir" arch/x86_64/airootfs.sfs
unsquashfs -cat "$inspect_dir/arch/x86_64/airootfs.sfs" root/get-arch.json > "$inspect_dir/get-arch.json"
unsquashfs -cat "$inspect_dir/arch/x86_64/airootfs.sfs" root/get-arch-install > "$inspect_dir/get-arch-install"
unsquashfs -cat "$inspect_dir/arch/x86_64/airootfs.sfs" root/.zlogin > "$inspect_dir/zlogin"
cmp archinstall/get-arch.json "$inspect_dir/get-arch.json"
cmp archiso/get-arch-install "$inspect_dir/get-arch-install"
grep -Fx '~/.automated_script.sh' "$inspect_dir/zlogin"
grep -Fx 'bash /root/get-arch-install' "$inspect_dir/zlogin"
rm -rf "$inspect_dir"
```

Expected: both `cmp` commands exit 0 and both `.zlogin` lines are found exactly.

- [ ] **Step 4: Boot the ISO under UEFI QEMU**

Run:

```bash
run_archiso -u -i "$iso"
```

Expected: the official live environment reaches tty1, root autologin occurs, network becomes usable through QEMU's default networking, and Archinstall launches with the embedded preset.

- [ ] **Step 5: Exercise recovery-shell and one-shot behavior manually**

Inside the VM:

1. cancel or exit Archinstall without installing to any virtual disk;
2. confirm the root shell remains usable;
3. run `cat /run/get-arch-install.started` or `test -e /run/get-arch-install.started` and confirm the sentinel exists;
4. start a fresh login shell with `exec zsh -l` and confirm Archinstall does **not** automatically launch again;
5. verify `archinstall --config /root/get-arch.json` manually starts the guided installer when deliberately invoked;
6. exit the VM without performing a real installation.

Expected: all six observations match the design.

- [ ] **Step 6: Re-run repository verification after the real build**

Run:

```bash
bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run scripts/build-iso archiso/get-arch-install
./tests/run
printf 'ciuser\nci-host\n' | ./get-arch --check
git status --short
```

Expected: all verification passes and the generated `out/` artifact is not staged for commit.

- [ ] **Step 7: Open the implementation PR without flashing**

Push `feature/custom-archiso` and open a PR against `master` summarizing:

- launcher one-shot/network behavior;
- safe current-`releng` overlay/build behavior;
- exact Archiso version used for the successful local build;
- exact generated ISO path;
- structural verification results;
- QEMU smoke-test results;
- explicit statement that no USB was flashed.

Do not merge until the PR receives final adversarial review.

---

## Plan self-review

- **Spec coverage:** launcher, network fallback, sentinel, canonical preset reuse, upstream `.zlogin` assertion, `archinstall` package assertion, version reporting, disposable build state, no privilege escalation, structural CI, real ISO inspection, QEMU smoke test, recovery shell, retry path, AUR deferral, and USB-flashing boundary are all assigned to explicit tasks.
- **Placeholder scan:** the only angle-bracket placeholder is the runtime-generated ISO filename in manual commands; the builder itself prints the exact path, so the executor substitutes that concrete output rather than inventing configuration.
- **Interface consistency:** the launcher path is consistently `archiso/get-arch-install` in the repository and `/root/get-arch-install` in the live image; the preset path is consistently `archinstall/get-arch.json` in the repository and `/root/get-arch.json` in the live image; the build output defaults consistently to `out/`.
