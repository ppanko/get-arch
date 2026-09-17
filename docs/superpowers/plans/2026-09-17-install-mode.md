# get-arch Install Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tested `get-arch --install-mode` that provisions Archinstall's newly installed target without changing machine-specific installation choices.

**Architecture:** A global mode flag selects a narrow alternate orchestration path while retaining the existing modules and normal-mode behavior. Install mode discovers existing identity from target files, uses offline systemd enablement, remains noninteractive under Archinstall `custom_commands`, and explicitly defers AUR work until a real interactive first-boot session is available.

**Tech Stack:** Bash, Arch Linux pacman/systemd tools, shell-based regression tests, ShellCheck

**Spec:** `docs/superpowers/specs/2026-09-17-install-mode-design.md`

## Global Constraints

- Do not invoke `arch-chroot`; Archinstall already runs the command inside the target.
- Do not build or flash the custom ISO.
- Do not create users, set passwords, or change hostname in install mode.
- Do not start services in install mode.
- Do not introduce passwordless or temporary sudo policy.
- Do not require interactive authentication from Archinstall `custom_commands`.
- Preserve normal mode as closely as possible.

---

### Task 1: CLI and orchestration separation

**Files:**
- Modify: `tests/test_cli.sh`
- Modify: `tests/test_orchestration.sh`
- Modify: `get-arch`
- Modify: `lib/common.sh`

**Interfaces:**
- Produces: `INSTALL_MODE` boolean, `--install-mode`, `--user USER`, and separate normal/install orchestration branches.
- Consumes: existing workstation module functions.

- [ ] Add CLI tests for install mode, explicit user, missing user argument, and rejecting `--user` outside install mode.
- [ ] Run `bash tests/test_cli.sh` and confirm failure because the options do not exist.
- [ ] Implement minimal parsing and validation.
- [ ] Run `bash tests/test_cli.sh` and confirm success.
- [ ] Add orchestration tests proving normal mode retains prompt/upgrade behavior while install mode selects installed identity, skips upgrade, and defers AUR work.
- [ ] Run `bash tests/test_orchestration.sh` and confirm failure on the missing install branch.
- [ ] Implement the orchestration split and confirm the test succeeds.
- [ ] Commit the CLI/orchestration increment.

### Task 2: Existing identity selection and mutation boundaries

**Files:**
- Modify: `tests/test_identity.sh`
- Modify: `modules/identity.sh`

**Interfaces:**
- Produces: `select_installed_identity` and install-aware `configure_identity` behavior.
- Consumes: `INSTALL_MODE`, optional `USERNAME`, `system_path`, and the existing validation/sudo-policy helpers.

- [ ] Add tests using target `/etc/passwd`, `/etc/login.defs`, and `/etc/hostname` fixtures for sole-user selection, explicit selection, zero/multiple-user failures, invalid hostname, and absence of `useradd`, `passwd`, and `hostnamectl` mutations.
- [ ] Run `bash tests/test_identity.sh` and confirm failure because installed identity selection is absent.
- [ ] Implement normal-login enumeration, deterministic selection, installed hostname validation, and reuse of wheel/sudo policy without identity mutation.
- [ ] Run `bash tests/test_identity.sh` and confirm success, including all existing normal-mode cases.
- [ ] Commit the identity increment.

### Task 3: Offline service and network semantics

**Files:**
- Modify: `tests/test_common.sh`
- Modify: `tests/test_modules.sh`
- Modify: `lib/common.sh`
- Modify: `modules/network.sh`

**Interfaces:**
- Produces: mode-aware target-only service enablement and activity-free network conflict detection.
- Consumes: `INSTALL_MODE`, `ensure_service_enabled`, `ensure_service_started`, and `NETWORK_INTERFACES`.

- [ ] Add tests proving install mode uses `systemctl --root=/ is-enabled/enable`, never invokes `start`/`is-active`, and normal mode keeps existing behavior.
- [ ] Add network tests proving install mode ignores live-active-only conflicts but rejects target-enabled conflicts.
- [ ] Run the focused tests and confirm the new assertions fail.
- [ ] Implement mode-aware service helpers and network checks.
- [ ] Run the focused tests and confirm success.
- [ ] Commit the service/network increment.

### Task 4: Noninteractive AUR deferral

**Files:**
- Modify: `tests/test_modules.sh`
- Modify: `tests/test_orchestration.sh`
- Modify: `modules/aur.sh`
- Modify: `get-arch`

**Interfaces:**
- Produces: `defer_aur_packages_install_mode`, which reports the declared AUR package set without opening a user/PTY session.
- Consumes: `load_aur_packages` and logging helpers.

- [ ] Add a regression test proving install mode opens no target-user AUR session and invokes no `sudo`, `makepkg`, or `paru` path.
- [ ] Run the focused tests and confirm failure because the deferral entry point is missing.
- [ ] Implement explicit AUR deferral while leaving normal-mode AUR functions unchanged.
- [ ] Run the focused tests and confirm success.
- [ ] Commit the AUR fix.

### Task 5: Documentation and complete verification

**Files:**
- Modify: `README.md`
- Modify as required by failures: implementation/tests above

**Interfaces:**
- Produces: documented install-mode usage and final verified branch.
- Consumes: all preceding tasks.

- [ ] Document install-mode boundaries and the expected Archinstall custom-command context without adding ISO implementation.
- [ ] Document why AUR work is deferred until an interactive first-boot path exists.
- [ ] Run `bash -n get-arch lib/*.sh modules/*.sh tests/*.sh tests/run`.
- [ ] Run `shellcheck get-arch lib/*.sh modules/*.sh tests/*.sh tests/run`.
- [ ] Run `./tests/run`.
- [ ] Run non-destructive top-level normal and install-mode check regressions.
- [ ] Review the diff against every specification item and fix any gap through a failing regression test first.
- [ ] Push the branch and keep the PR open for review without merging it.
