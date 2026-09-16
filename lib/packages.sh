#!/usr/bin/env bash

OFFICIAL_PACKAGE_GROUPS=(desktop development data-science documents media utilities)

parse_package_file() {
  awk '{ sub(/[[:space:]]*#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length) print }' "$1"
}

load_official_packages() {
  local group
  for group in "${OFFICIAL_PACKAGE_GROUPS[@]}"; do
    parse_package_file "$REPO_ROOT/packages/$group"
  done | sort -u
}

load_aur_packages() {
  parse_package_file "$REPO_ROOT/packages/aur" | sort -u
}

ensure_packages() {
  (($#)) || return 0
  run_mutation "Install packages: $*" pacman -S --needed --noconfirm -- "$@"
}

upgrade_system() {
  run_mutation 'Upgrade Arch system' pacman -Syu --noconfirm
}

validate_package_files() {
  local file entry
  for file in "$REPO_ROOT"/packages/*; do
    [[ -f "$file" ]] || continue
    while IFS= read -r entry; do
      [[ $entry =~ ^[[:alnum:]@._+:-]+$ ]] || die "Invalid package entry '$entry' in ${file#$REPO_ROOT/}"
    done < <(parse_package_file "$file")
  done
}

install_declared_official_packages() {
  local packages=()
  mapfile -t packages < <(load_official_packages)
  ensure_packages "${packages[@]}"
}
