#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

launcher=archiso/get-arch-install
helper=archiso/get-arch-disk-config

if [[ ! -f $launcher ]]; then
  printf 'FAIL: missing Archiso launcher: %s\n' "$launcher" >&2
  exit 1
fi

if [[ ! -f $helper ]]; then
  printf 'FAIL: missing Archiso disk helper: %s\n' "$helper" >&2
  exit 1
fi

python - "$launcher" "$helper" <<'PY'
from pathlib import Path
import re
import sys

launcher_path = Path(sys.argv[1])
helper_path = Path(sys.argv[2])
launcher = launcher_path.read_text(encoding='utf-8')
helper = helper_path.read_text(encoding='utf-8')

assert launcher.startswith('#!/usr/bin/env bash\nset -euo pipefail\n'), launcher[:80]
assert '/dev/tty1' in launcher
assert '/run/get-arch-install.started' in launcher
assert '/root/get-arch.json' in launcher
assert '/run/get-arch.json' in launcher
assert 'archinstall --config "$config_path"' in launcher
assert 'iwctl' in launcher
assert 'curl ' in launcher
assert 'lsblk' in launcher
assert 'WIPE ' in launcher
assert 'RM' in launcher
assert 'TRAN' in launcher
assert 'create one normal user' in launcher.lower()

sentinel = ': > "$SENTINEL"'
install = 'archinstall --config "$config_path"'
assert launcher.index(sentinel) < launcher.index(install)
assert 'network_ready' in launcher

manual = 'archinstall --config /root/get-arch.json'
assert launcher.count(manual) >= 1

assert helper.startswith('#!/usr/bin/env python3\n'), helper[:80]
assert 'suggest_single_disk_layout' in helper
assert 'FilesystemType.EXT4' in helper
assert 'separate_home=False' in helper
assert "'disk_config'" in helper or '"disk_config"' in helper
assert 'python "$DISK_HELPER"' in launcher

for text in (launcher, helper):
    for forbidden in (
        'reboot',
        'poweroff',
        'shutdown',
        'mkfs',
        'fdisk',
        'parted',
        'wipefs',
        'cryptsetup',
        'dd if=',
        'wpa_passphrase',
    ):
        assert forbidden not in text, forbidden
    assert not re.search(r'(?m)^\s*sudo\s', text), 'sudo command'
PY

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
assert 'archiso/get-arch-disk-config' in text
assert 'pacman -Q archiso' in text
assert "grep -Fxq 'archinstall'" in text
assert "grep -Fxc '~/.automated_script.sh'" in text
assert 'bash /root/get-arch-install' in text
assert 'mkarchiso -v -w "$work_dir" -o "$build_output" "$profile_dir"' in text
assert 'trap cleanup EXIT HUP INT TERM' in text
assert 'unshare --map-auto --map-root-user -- rm -rf -- "$tmp_root"' in text

copy_profile = 'cp -a -- "$RELENG_DIR" "$profile_dir"'
copy_preset = 'cp -- "$PRESET" "$profile_dir/airootfs/root/get-arch.json"'
copy_launcher = 'cp -- "$LAUNCHER" "$profile_dir/airootfs/root/get-arch-install"'
copy_helper = 'cp -- "$DISK_HELPER" "$profile_dir/airootfs/root/get-arch-disk-config"'
patch_zlogin = "printf '\\nbash /root/get-arch-install\\n' >> \"$zlogin\""
assert text.index(copy_profile) < text.index(copy_preset) < text.index(copy_launcher) < text.index(copy_helper) < text.index(patch_zlogin)

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
