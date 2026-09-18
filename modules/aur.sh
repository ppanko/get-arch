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

aur_completion_user_home() {
  local passwd_file home
  passwd_file=$(system_path /etc/passwd)
  home=$(awk -F: -v username="$USERNAME" '$1 == username { print $6; exit }' "$passwd_file")
  if [[ -z $home || $home != /* ]]; then
    die "Could not determine the home directory for installed user '$USERNAME'."
    return 1
  fi
  printf '%s\n' "$home"
}

schedule_aur_completion_install_mode() {
  local packages=()
  local home uid gid state_dir autostart_dir helper_path package_tmp desktop_tmp

  mapfile -t packages < <(load_aur_packages)
  if ((${#packages[@]} == 0)); then
    log_skip 'No AUR packages declared'
    return 0
  fi

  ensure_packages base-devel git rust gnome-terminal

  home=$(aur_completion_user_home)
  uid=$(id -u "$USERNAME")
  gid=$(id -g "$USERNAME")
  state_dir=$(system_path "$home/.local/state/get-arch")
  autostart_dir=$(system_path "$home/.config/autostart")
  helper_path=$(system_path /usr/local/lib/get-arch/complete-aur)

  package_tmp=$(mktemp)
  desktop_tmp=$(mktemp)
  printf '%s\n' "${packages[@]}" >"$package_tmp"
  cat >"$desktop_tmp" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Finish get-arch installation
Comment=Install deferred AUR packages
Exec=/usr/bin/gnome-terminal --wait --title=get-arch-AUR -- /usr/bin/bash /usr/local/lib/get-arch/complete-aur
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOP

  run_mutation 'Install first-login AUR completion helper' \
    install -Dm0755 "$REPO_ROOT/scripts/complete-aur" "$helper_path"
  run_mutation 'Prepare first-login AUR completion directories' \
    install -d -m0700 -o "$uid" -g "$gid" "$state_dir" "$autostart_dir"
  run_mutation 'Record pending AUR package set' \
    install -m0600 -o "$uid" -g "$gid" "$package_tmp" "$state_dir/aur-packages"
  run_mutation 'Schedule first-login AUR completion' \
    install -m0644 -o "$uid" -g "$gid" "$desktop_tmp" \
    "$autostart_dir/get-arch-aur-completion.desktop"

  rm -f "$package_tmp" "$desktop_tmp"
  log_info "AUR completion scheduled for the first GNOME login of $USERNAME: ${packages[*]}"
}
