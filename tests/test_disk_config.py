#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'archiso' / 'get-arch-disk-config'


def install_fake_archinstall():
    calls = {}

    archinstall = types.ModuleType('archinstall')
    lib = types.ModuleType('archinstall.lib')
    disk = types.ModuleType('archinstall.lib.disk')
    handler_module = types.ModuleType('archinstall.lib.disk.device_handler')
    menu_module = types.ModuleType('archinstall.lib.disk.disk_menu')
    models = types.ModuleType('archinstall.lib.models')
    device_module = types.ModuleType('archinstall.lib.models.device')

    fake_device = object()

    class Handler:
        def get_device(self, path):
            calls['device_path'] = path
            return fake_device

    async def suggest_single_disk_layout(device, filesystem_type=None, separate_home=None):
        calls['device'] = device
        calls['filesystem_type'] = filesystem_type
        calls['separate_home'] = separate_home

        class Modification:
            def json(self):
                return {
                    'device': str(calls['device_path']),
                    'wipe': True,
                    'partitions': [
                        {'fs_type': 'fat32', 'mountpoint': '/boot'},
                        {'fs_type': 'ext4', 'mountpoint': '/'},
                    ],
                }

        return Modification()

    class FakeDiskLayoutType:
        Default = 'default-enum'

    class FakeFilesystemType:
        EXT4 = 'ext4-enum'

    class FakeDiskLayoutConfiguration:
        def __init__(self, config_type, device_modifications):
            calls['config_type'] = config_type
            calls['device_modifications'] = device_modifications
            self.device_modifications = device_modifications

        def json(self):
            return {
                'config_type': 'default_layout',
                'device_modifications': [m.json() for m in self.device_modifications],
            }

    handler_module.device_handler = Handler()
    menu_module.suggest_single_disk_layout = suggest_single_disk_layout
    device_module.DiskLayoutConfiguration = FakeDiskLayoutConfiguration
    device_module.DiskLayoutType = FakeDiskLayoutType
    device_module.FilesystemType = FakeFilesystemType

    for name, module in {
        'archinstall': archinstall,
        'archinstall.lib': lib,
        'archinstall.lib.disk': disk,
        'archinstall.lib.disk.device_handler': handler_module,
        'archinstall.lib.disk.disk_menu': menu_module,
        'archinstall.lib.models': models,
        'archinstall.lib.models.device': device_module,
    }.items():
        sys.modules[name] = module

    return calls, FakeFilesystemType, FakeDiskLayoutType


def load_helper():
    loader = importlib.machinery.SourceFileLoader('get_arch_disk_config', str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def test_generates_archinstall_owned_ext4_layout():
    calls, filesystem_type, layout_type = install_fake_archinstall()
    helper = load_helper()

    disk_config = helper.generate_disk_config(Path('/dev/nvme0n1'))

    assert calls['device_path'] == Path('/dev/nvme0n1')
    assert calls['filesystem_type'] == filesystem_type.EXT4
    assert calls['separate_home'] is False
    assert calls['config_type'] == layout_type.Default
    assert disk_config['config_type'] == 'default_layout'
    assert disk_config['device_modifications'][0]['wipe'] is True
    assert disk_config['device_modifications'][0]['partitions'][-1]['fs_type'] == 'ext4'
    assert all(p['mountpoint'] != '/home' for p in disk_config['device_modifications'][0]['partitions'])


def test_merge_preserves_portable_preset_and_adds_only_disk_config():
    install_fake_archinstall()
    helper = load_helper()
    base = {
        'kernels': ['linux'],
        'network_config': {'type': 'nm'},
        'custom_commands': ['provision'],
        'timezone': 'America/New_York',
    }
    disk_config = {'config_type': 'default_layout', 'device_modifications': []}

    merged = helper.merge_config(base, disk_config)

    assert base == {
        'kernels': ['linux'],
        'network_config': {'type': 'nm'},
        'custom_commands': ['provision'],
        'timezone': 'America/New_York',
    }
    assert merged['kernels'] == ['linux']
    assert merged['network_config'] == {'type': 'nm'}
    assert merged['custom_commands'] == ['provision']
    assert merged['timezone'] == 'America/New_York'
    assert merged['disk_config'] == disk_config
    assert 'disk_encryption' not in merged
    assert 'lvm_config' not in merged


if __name__ == '__main__':
    test_generates_archinstall_owned_ext4_layout()
    test_merge_preserves_portable_preset_and_adds_only_disk_config()
    print('ok')
