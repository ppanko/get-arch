# MT7610U suspend/resume investigation

This note covers the MediaTek MT7610U USB Wi-Fi adapter observed as USB ID `148f:761a` with the `mt76x0u` kernel driver. It is an investigation guide, not a default get-arch workaround.

## Current status

The observed failure begins in the kernel driver during resume:

```text
mt76x0u ... resume error -110
```

NetworkManager and wpa_supplicant then fail because the resumed interface never becomes usable. Physically unplugging and reconnecting the adapter creates a new working USB device, but recovery can still fail when the saved NetworkManager profile is pinned to the old interface name.

Current mainline still uses the same mt76x0u USB resume sequence, and the mt76 project has a long-standing open MT7610U suspend/resume report with the same `-110` timeout class. The log identifies the failure as part of the driver's resume reinitialization path, but does not identify which internal operation returned `-ETIMEDOUT`.

The affected workstation has now reproduced the failure on both the regular and LTS kernels. A narrowly scoped interface unbind/rebind experiment has also recovered two controlled LTS suspend cycles. That is enough to continue testing the approach, but not enough to install it by default: the prototype has not completed an overnight cycle and is not yet safe for multiple mt76x0u adapters. get-arch therefore does not currently install a sleep hook, force a module reload, change USB power policy, or rewrite NetworkManager profiles automatically.

Upstream references:

- https://github.com/torvalds/linux/blob/master/drivers/net/wireless/mediatek/mt76/mt76x0/usb.c
- https://github.com/openwrt/mt76/issues/290
- https://www.networkmanager.dev/docs/api/latest/nm-settings-nmcli.html

## Reproduce and capture

Before suspending, record the adapter, interface, profile, and kernel:

```bash
uname -r
lsusb -d 148f:761a
nmcli device status
nmcli -f NAME,UUID,TYPE,DEVICE,AUTOCONNECT connection show
```

For the Wi-Fi profile in use, record its interface binding:

```bash
UUID=<connection-uuid>
nmcli -g connection.id,connection.uuid,connection.interface-name connection show uuid "$UUID"
```

Suspend normally:

```bash
systemctl suspend
```

After resume, capture the driver and network-manager failure before rebooting or unplugging the adapter:

```bash
journalctl -b -k --no-pager | grep -E 'mt76x0u|resume error|timed out'
journalctl -b -u NetworkManager --no-pager | grep -E 'wlp|wlan|timed out|supplicant|mismatch'
nmcli device status
```

The important distinction is whether the first failure is the kernel `mt76x0u` resume timeout. Interface naming and profile compatibility are secondary recovery problems and should not be mistaken for the original failure.

## Results on the affected workstation

The affected USB ID `148f:761a` adapter was tested with deep S3 suspend on a Dell OptiPlex 9020:

- Linux `7.2.6-arch2-1` completed one roughly 22-hour suspend successfully, then failed after a later roughly 13-hour suspend with `mt76x0u ... resume error -110`.
- Linux LTS `6.18.54-1-lts` reproduced the same `-110` failure after a short controlled suspend. NetworkManager then reported link-change timeouts and wpa_supplicant could not reclaim the unusable interface.
- The failure is therefore not specific to Linux 7.2 and does not require a long suspend. Its occurrence is intermittent.

The saved `Oliver_WiFi` profile was bound to `wlp0s20u5`. A temporary clone of that profile was bound to the deliberately wrong name `wlan0`; NetworkManager rejected activation on `wlp0s20u5` because the interface names did not match. Clearing only the clone's `connection.interface-name` allowed immediate activation on `wlp0s20u5`. The clone was then deleted and the original profile was restored unchanged. This confirms the interface binding as a separate recovery barrier when a re-enumerated adapter cannot reclaim its original name.

An experimental system-sleep hook then unbound only USB interface `1-5:1.0` from the `mt76x0u` driver before suspend and rebound that same interface after resume. Two controlled LTS cycles completed without `resume error -110`; the driver reprobed and NetworkManager reconnected the original profile automatically in about five seconds. This works by avoiding the driver's failing resume callback and taking the normal disconnect/probe path instead.

The experiment does not yet justify a default get-arch workaround. Before shipping it, repeat an overnight cycle and harden the hook so it:

- verifies USB ID `148f:761a` before changing a binding;
- records and restores the exact matching interface without affecting another mt76x0u adapter;
- handles no-device, multiple-device, bind-failure, and stale-state cases safely;
- runs only for suspend actions for which it has been tested;
- has regression coverage that uses fake sysfs state rather than touching host hardware.

## Test re-enumeration recovery without broad profile changes

NetworkManager documents `connection.interface-name` as a hard interface binding. When it is unset, the profile may attach to any otherwise-compatible interface. This makes the binding worth testing separately from the kernel bug.

First record the existing value:

```bash
UUID=<connection-uuid>
OLD_IFNAME=$(nmcli -g connection.interface-name connection show uuid "$UUID")
printf 'Original interface binding: %s\n' "$OLD_IFNAME"
```

Only after confirming the UUID is the affected Wi-Fi profile, clear that one profile's interface-name binding:

```bash
sudo nmcli connection modify uuid "$UUID" connection.interface-name ""
```

Then physically unplug and reconnect the MT7610U adapter. Check the new interface name and try the same profile:

```bash
nmcli device status
sudo nmcli connection up uuid "$UUID"
```

If the adapter re-enumerates under a different name such as `wlan0` and the profile now connects, that confirms the interface binding was blocking recovery after re-enumeration. It does not fix the underlying suspend/resume timeout.

On systems with multiple Wi-Fi adapters, leaving the binding unset may allow the profile to match another compatible Wi-Fi device. Restore the original binding after the experiment unless the unbound behavior is intentionally preferred:

```bash
sudo nmcli connection modify uuid "$UUID" connection.interface-name "$OLD_IFNAME"
```

If `OLD_IFNAME` was originally empty, leave the property unset instead of writing a new interface name.

## What not to automate yet

Do not add any of the following to get-arch until they have been validated repeatedly on the affected hardware:

- a systemd sleep hook that unloads/reloads `mt76x0u`;
- a broad interface unbind/rebind hook that affects mt76x0u devices other than USB ID `148f:761a`;
- USB autosuspend or power-control overrides;
- generic NetworkManager profile rewrites;
- forced interface renaming;
- a blanket kernel-module reset affecting unrelated mt76 devices.

A get-arch workaround should be hardware-scoped and should only be added after repeated suspend/resume tests show that it actually prevents or safely recovers the failure.
