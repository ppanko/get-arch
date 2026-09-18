#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

launcher=archiso/get-arch-install
smoke=scripts/smoke-iso

[[ -f $launcher ]] || { printf 'FAIL: missing launcher\n' >&2; exit 1; }
[[ -f $smoke ]] || { printf 'FAIL: missing disposable-disk smoke runner\n' >&2; exit 1; }

python - "$launcher" "$smoke" <<'PY'
from pathlib import Path
import sys

launcher = Path(sys.argv[1]).read_text(encoding='utf-8')
smoke = Path(sys.argv[2]).read_text(encoding='utf-8')

assert 'HOTPLUG' in launcher, 'disk eligibility must inspect hotplug state'
assert 'hotplug' in launcher.lower(), 'hotplugged disks must be excluded from automation'
assert 'iscsi' in launcher.lower(), 'remote iSCSI transport must be excluded from automation'
assert 'Press Enter to continue to Archinstall' in launcher, 'account guidance must remain visible until acknowledged'
assert 'safe internal disk' not in launcher.lower(), 'launcher must not overstate what disk detection proves'

assert smoke.startswith('#!/usr/bin/env bash\nset -euo pipefail\n')
assert 'qemu-img create' in smoke
assert 'qemu-system-x86_64' in smoke
assert 'OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd' in smoke
assert 'OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd' in smoke
assert 'OVMF_CODE.secboot' not in smoke
assert 'property=secure' not in smoke
assert "-machine q35" in smoke
assert 'disk_count' in smoke
assert '1|2' in smoke
assert '64G' in smoke
assert 'rm -rf' in smoke
PY
