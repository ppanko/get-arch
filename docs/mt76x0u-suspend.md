# MT7610U suspend/resume investigation

This note covers the MediaTek MT7610U USB Wi-Fi adapter observed as USB ID `148f:761a` with the `mt76x0u` kernel driver. It is an investigation guide, not a default get-arch workaround.

## Current status

The observed failure begins in the kernel driver during resume:

```text
mt76x0u ... resume error -110
```

NetworkManager and wpa_supplicant then fail because the resumed interface never becomes usable. Physically unplugging and reconnecting the adapter creates a new working USB device, but recovery can still fail when the saved NetworkManager profile is pinned to the old interface name.

Current mainline still uses the same mt76x0u USB resume sequence, and the mt76 project has a long-standing open MT7610U suspend/resume report with the same `-110` timeout class. get-arch therefore does not install a sleep hook, force a driver reload, change USB power policy, or rewrite NetworkManager profiles automatically.

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
- USB autosuspend or power-control overrides;
- generic NetworkManager profile rewrites;
- forced interface renaming;
- a blanket kernel-module reset affecting unrelated mt76 devices.

A get-arch workaround should be hardware-scoped and should only be added after repeated suspend/resume tests show that it actually prevents or safely recovers the failure.
