# Platform Profile Daemon

Minimal Power Profiles Daemon-compatible service for Linux 7.3.0-rc1+ Dynamic EPP.

```text
/sys/firmware/acpi/platform_profile
```

It lets desktop power controls switch the kernel platform profile without adding
CPU governor, static EPP, TLP, or vendor policy management.

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
> v1.1.0 initializes Dynamic EPP through a short-lived systemd service before
> starting the daemon. The `amd_dynamic_epp=enable` kernel command-line option
> is no longer required or supported. The daemon then bridges desktop power
> controls and `platform_profile`.

See [AGENTS.md](AGENTS.md) for initialization, privilege boundaries, and
implementation constraints.

## Install

The Arch package installs both executables, both units, D-Bus policy/activation,
and Polkit policy. For a staged manual installation:

```sh
DESTDIR="$PWD/stage" zig build install -Doptimize=ReleaseFast --prefix /usr
```

Install the staged files individually with appropriate permissions: executables
0755, units and policy files 0644. Reload systemd after installing. Enable only
`platform-profile-daemon.service`; its dependency starts the init service.

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

### Initialization fails

Inspect the initialization service logs:

```sh
journalctl -u platform-profile-daemon-init.service -b
```

After resolving a failure, restore a supported global profile if necessary and
restart the init service, then start the daemon. Avoid changing profiles during
initialization because the saved initial profile is restored at the end.

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

An initial `custom` or unsupported profile prevents startup. If `custom` appears
while running, the desktop keeps showing the last valid profile. Explicitly
select a supported profile to synchronize the kernel handlers again. The daemon
does not automatically choose `balanced`.
