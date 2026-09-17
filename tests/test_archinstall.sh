#!/usr/bin/env bash
set -euo pipefail

preset=archinstall/get-arch.json

if [[ ! -f $preset ]]; then
  printf 'FAIL: missing archinstall preset: %s\n' "$preset" >&2
  exit 1
fi

python - "$preset" <<'PY'
import json
import re
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

pinned_revision = 'bde5f79e00db0f346e035c1a90366309274fedc6'
custom_commands = config.get('custom_commands')
assert isinstance(custom_commands, list), custom_commands
assert len(custom_commands) == 1, custom_commands

command = custom_commands[0]
lines = command.splitlines()
assert lines[0] == 'set -euo pipefail', lines

cleanup_command = 'rm -rf /opt/get-arch'
clone_command = (
    'git clone --no-checkout https://github.com/ppanko/get-arch.git '
    '/opt/get-arch'
)
checkout_command = (
    f'git -C /opt/get-arch checkout --detach {pinned_revision}'
)
install_command = '/opt/get-arch/get-arch --install-mode'
assert cleanup_command in lines, lines
assert clone_command in lines, lines
assert checkout_command in lines, lines
assert install_command in lines, lines
assert [line for line in lines if line.startswith('rm ')] == [cleanup_command], lines
assert lines.index(cleanup_command) < lines.index(clone_command), lines
assert lines.index(clone_command) < lines.index(checkout_command), lines
assert lines.index(checkout_command) < lines.index(install_command), lines

assert re.findall(r'(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])', command) == [
    pinned_revision
], command
assert [line for line in lines if ' checkout ' in line] == [checkout_command], lines
assert 'master' not in command, command
assert 'HEAD' not in command, command
assert 'arch-chroot' not in command, command
assert '|| true' not in command, command
assert 'set +e' not in command, command

for forbidden_provisioning_step in (
    'sudo -v',
    'makepkg',
    'paru',
    'NOPASSWD',
):
    assert forbidden_provisioning_step not in command, forbidden_provisioning_step

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
