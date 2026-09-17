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
