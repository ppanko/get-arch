#!/usr/bin/env bash
set -euo pipefail

preset=archinstall/get-arch.json

if [[ ! -f $preset ]]; then
  printf 'FAIL: missing archinstall preset: %s\n' "$preset" >&2
  exit 1
fi

python - "$preset" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as handle:
    config = json.load(handle)

assert config['kernels'] == ['linux'], config.get('kernels')
assert config['network_config'] == {'type': 'nm'}, config.get('network_config')
assert config['ntp'] is True, config.get('ntp')
assert config['packages'] == ['git'], config.get('packages')
assert config['profile_config'] == {
    'gfx_driver': None,
    'greeter': None,
    'profile': {
        'custom_settings': {},
        'details': [],
        'main': 'Minimal',
    },
}, config.get('profile_config')

for unsafe_or_machine_specific in (
    'auth_config',
    'bootloader_config',
    'disk_config',
    'hostname',
    'locale_config',
    'timezone',
):
    assert unsafe_or_machine_specific not in config, unsafe_or_machine_specific
PY
