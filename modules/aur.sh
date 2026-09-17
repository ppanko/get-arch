#!/usr/bin/env bash

ensure_aur_helper() {
  if command -v paru >/dev/null 2>&1; then
    log_skip 'paru already installed'
    return 0
  fi

  ensure_packages base-devel git rust

  local bootstrap
  bootstrap=$(cat <<'SH'
set -euo pipefail
build_dir="$HOME/.cache/get-arch/paru"
rm -rf "$build_dir"
mkdir -p "$(dirname "$build_dir")"
git clone https://aur.archlinux.org/paru.git "$build_dir"
cd "$build_dir"
makepkg -si --needed --noconfirm
SH
)
  run_as_user_mutation "$USERNAME" 'Build paru AUR helper' bash -lc "$bootstrap"
}

install_aur_packages() {
  local packages=()
  mapfile -t packages < <(load_aur_packages)
  if ((${#packages[@]} == 0)); then
    log_skip 'No AUR packages declared'
    return 0
  fi
  run_as_user_mutation "$USERNAME" "Install AUR packages: ${packages[*]}" \
    paru -S --needed --noconfirm -- "${packages[@]}"
}

install_aur_packages_install_mode() {
  local packages=() session
  mapfile -t packages < <(load_aur_packages)
  if ((${#packages[@]} == 0)); then
    log_skip 'No AUR packages declared'
    return 0
  fi

  ensure_packages base-devel git rust
  session=$(cat <<'SH'
set -euo pipefail
packages=("$@")

# Authenticate once on this PTY. makepkg and paru remain unprivileged and use
# sudo only when pacman must install dependencies or completed packages.
sudo -v

if ! command -v paru >/dev/null 2>&1; then
  build_dir="$HOME/.cache/get-arch/paru"
  rm -rf "$build_dir"
  mkdir -p "$(dirname "$build_dir")"
  git clone https://aur.archlinux.org/paru.git "$build_dir"
  cd "$build_dir"
  makepkg -si --needed --noconfirm
fi

paru -S --needed --noconfirm -- "${packages[@]}"
SH
)
  run_as_user_mutation "$USERNAME" "Provision AUR packages: ${packages[*]}" \
    bash -lc "$session" get-arch-aur "${packages[@]}"
}
