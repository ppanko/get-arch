# Phase 1 Dependency Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing PipeWire, GNOME calendar, wireless, and FAT target paths complete on fresh get-arch installations.

**Architecture:** Extend the existing capability-owned package calls for audio, desktop, and network. Add the small FAT checker package to the canonical utilities manifest so normal and install modes share the same target behavior. After implementation is committed, advance the Archinstall preset pin to that immutable implementation commit.

**Tech Stack:** Bash, Arch Linux packages, pacman, Archinstall JSON, shell regression tests.

**Spec:** GitHub issues #10, #11, #12, and #13 plus the user-provided Phase 1 requirements.

## Global Constraints

- Keep packages owned by the existing capability that consumes them.
- Prefer unconditional installation for small dependencies over new hardware or filesystem detection branches.
- Preserve idempotence through the existing `pacman -S --needed` path in normal and install modes.
- Do not configure online accounts, start new services, or make unrelated package changes.
- Keep the Archinstall preset pinned to an immutable implementation commit and require a merge commit so the pin remains reachable.

## Review Focus

- A missing `rtkit` entry must break the audio module contract test.
- A missing `evolution-data-server` entry must break the desktop module contract test.
- A missing `wireless-regdb` entry must break the network module contract test in both normal and install-mode paths.
- A missing `dosfstools` entry must break the canonical package-set regression test.
- A stale Archinstall revision must break the preset pin test.

---

### Task 1: Add failing dependency regressions

**Files:**
- Modify: `tests/test_modules.sh`
- Modify: `tests/test_packages.sh`

**Interfaces:**
- Consumes: existing `configure_audio`, `configure_desktop`, `configure_network`, and `load_official_packages` behavior.
- Produces: regression expectations for all four issue dependencies.

- [ ] Update the audio contract expectation to require `rtkit`.
- [ ] Update the desktop contract expectation to require `evolution-data-server`.
- [ ] Update normal and install-mode network expectations to require `wireless-regdb`.
- [ ] Add `dosfstools` to the canonical required-package loop.
- [ ] Run `bash tests/test_modules.sh` and `bash tests/test_packages.sh`; verify both fail only because the four dependencies are absent.

### Task 2: Implement minimal package ownership changes

**Files:**
- Modify: `modules/audio.sh`
- Modify: `modules/desktop.sh`
- Modify: `modules/network.sh`
- Modify: `packages/utilities`

**Interfaces:**
- Consumes: `ensure_packages`, whose `pacman -S --needed` behavior provides shared normal/install-mode idempotence.
- Produces: complete dependency sets for existing capability entry points.

- [ ] Add `rtkit` to `configure_audio` without adding service management because Arch supplies D-Bus activation.
- [ ] Add `evolution-data-server` to `configure_desktop` without configuring an account.
- [ ] Add `wireless-regdb` to `configure_network` unconditionally.
- [ ] Add `dosfstools` to the utilities manifest so the installed target receives `fsck.fat`, `fsck.msdos`, and `fsck.vfat`.
- [ ] Run `bash tests/test_modules.sh` and `bash tests/test_packages.sh`; verify both pass.
- [ ] Run `./tests/run`; verify the full baseline remains green.
- [ ] Commit the tests and implementation.

### Task 3: Advance the immutable Archinstall provisioning pin

**Files:**
- Modify: `archinstall/get-arch.json`
- Modify: `tests/test_archinstall.sh`

**Interfaces:**
- Consumes: the Task 2 implementation commit hash.
- Produces: fresh Archinstall targets provisioned by the Phase 1 implementation.

- [ ] Replace the preset revision with the exact Task 2 implementation commit.
- [ ] Update the regression test's expected immutable revision.
- [ ] Run `bash tests/test_archinstall.sh`; verify it passes.
- [ ] Run `./tests/run`; verify the complete suite passes.
- [ ] Commit the pin update separately so the pinned implementation commit remains immutable.

### Task 4: Verify and open the focused PR

**Files:**
- Create temporarily: PR body outside the repository.

**Interfaces:**
- Consumes: the completed branch and full verification output.
- Produces: one unmerged reviewable PR referencing issues #10-#13.

- [ ] Run Bash syntax checks on repository shell files.
- [ ] Run ShellCheck using the repository/CI file set if available.
- [ ] Run `./tests/run` from a clean branch state and record the result.
- [ ] Review the diff against `origin/master` for scope and pin reachability.
- [ ] Push the branch and open a PR that closes #10, #11, #12, and #13.
- [ ] State that the PR must use a merge commit because the Archinstall preset pins the Task 2 commit.
- [ ] Do not merge; stop for review.
