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

> [!NOTE]
> This project is designed for users who enable the kernel Dynamic EPP function.
> The daemon writes `platform_profile`; the kernel then reads that platform
> profile and updates EPP automatically.

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
sudo ./zig-out/lib/platform-profile-daemon --platform-profile /tmp/platform_profile
```

### Validate

Run on the target machine:

```sh
sudo systemctl restart platform-profile-daemon.service
busctl --system status org.freedesktop.UPower.PowerProfiles
```

Check the current profile:

```sh
busctl --system get-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile
cat /sys/firmware/acpi/platform_profile
```

Test all supported profiles:

```sh
busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s power-saver
cat /sys/firmware/acpi/platform_profile

busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s balanced
cat /sys/firmware/acpi/platform_profile

busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s performance
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
confirm that D-Bus `ActiveProfile` and `/sys/firmware/acpi/platform_profile`
stay in sync.

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
busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s balanced
```

### `custom` profile

When `platform_profile` is `custom`, the daemon intentionally normalizes it by
writing `balanced`. D-Bus `ActiveProfile` then becomes `balanced`.

### Invalid or empty runtime refresh

The current kernel value must be one of:

```text
low-power
balanced
performance
```

Invalid, empty, or malformed runtime refreshes are ignored and must not
fabricate `balanced` changes.
