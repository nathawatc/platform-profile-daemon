# Platform Profile Daemon

Minimal Power Profiles Daemon-compatible service backed only by:

```text
/sys/firmware/acpi/platform_profile
```

It lets desktop power controls switch the kernel platform profile without adding
CPU governor, cpufreq, amd_pstate, EPP, TLP, or vendor policy management.

Fixed mapping:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

> [!NOTE]
> This project is intentionally small. It does not discover profiles from
> `platform_profile_choices`; it only supports the fixed mapping above.

## Build

```sh
zig build test
zig build -Doptimize=ReleaseFast
```

## Run

The daemon is intended to run through systemd:

```sh
sudo systemctl restart platform-profile-daemon.service
sudo systemctl status platform-profile-daemon.service
```

Do not normally run the daemon manually. It owns the system-bus name used by
desktop power controls:

```text
org.freedesktop.UPower.PowerProfiles
```

For local fake-sysfs development only:

```sh
printf 'balanced\n' > /tmp/platform_profile
zig build -Doptimize=ReleaseFast
sudo ./zig-out/bin/platform-profile-daemon --platform-profile /tmp/platform_profile
```

### Validate

Run on the target machine:

```sh
sudo systemctl restart platform-profile-daemon.service
busctl --system status org.freedesktop.UPower.PowerProfiles
```

Check the current profile:

```sh
powerprofilesctl get
cat /sys/firmware/acpi/platform_profile
```

Test all supported profiles:

```sh
powerprofilesctl set power-saver
cat /sys/firmware/acpi/platform_profile

powerprofilesctl set balanced
cat /sys/firmware/acpi/platform_profile

powerprofilesctl set performance
cat /sys/firmware/acpi/platform_profile
```

Expected kernel values:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

Optional smoke test:

```sh
sudo ./tools/dbus-smoke.sh
```

After CLI validation, switch profiles from the desktop widget or power menu and
confirm that `powerprofilesctl get` and
`/sys/firmware/acpi/platform_profile` stay in sync.

## Troubleshooting

### `Permission denied` when started manually

Run the systemd service instead:

```sh
sudo systemctl restart platform-profile-daemon.service
```

### `File exists` or bus name acquisition failure

Another process already owns the Power Profiles D-Bus name. Check the owner:

```sh
busctl --system status org.freedesktop.UPower.PowerProfiles
```

Stop the conflicting daemon if needed.

### Desktop widget cannot switch profiles

Reinstall the package or policy files, restart the service, then check logs:

```sh
journalctl -u platform-profile-daemon.service --since "10 min ago"
```

Also confirm the active desktop session can switch profiles with:

```sh
powerprofilesctl set balanced
```

### Invalid or empty startup profile

The current kernel value must be one of:

```text
low-power
balanced
performance
```

Invalid, empty, or malformed runtime refreshes are ignored and do not become
fake `balanced` changes.
