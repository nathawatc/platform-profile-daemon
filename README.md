# Platform Profile Daemon

Minimal Zig daemon that owns `org.freedesktop.UPower.PowerProfiles` and bridges
Power Profiles Daemon-compatible D-Bus profile names to one sysfs file only:

```text
/sys/firmware/acpi/platform_profile
```

Hardcoded mapping:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

The daemon intentionally does not read `platform_profile_choices`, does not
discover profiles, and does not tune CPU governors, cpufreq, amd_pstate, EPP, or
vendor policy.

## Design with kernel dynamic EPP

This daemon is designed to be used with a kernel that provides `dynamic_epp`.
The daemon does not write EPP values itself. Instead, desktop tools set a
Power Profiles Daemon-compatible D-Bus profile, this daemon writes the matching
kernel `platform_profile` value, and `dynamic_epp` observes that kernel profile
change to apply the appropriate EPP behavior.

Flow:

```text
desktop client -> D-Bus PowerProfiles API -> platform-profile-daemon
              -> /sys/firmware/acpi/platform_profile -> kernel dynamic_epp
```

This keeps userspace small and predictable: the only policy boundary exposed by
the daemon is the kernel platform profile.

## Build

```sh
zig build -Doptimize=ReleaseFast
```

## Test

```sh
zig build test
```

## Run against fake sysfs

```sh
printf 'balanced\n' > /tmp/platform_profile
zig build -Doptimize=ReleaseFast
sudo ./zig-out/bin/platform-profile-daemon --platform-profile /tmp/platform_profile
```

## Query

```sh
busctl --system get-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile
```

## D-Bus smoke test (system bus)

Run this manually on a machine with systemd and writable
`/sys/firmware/acpi/platform_profile`:

```sh
sudo systemctl restart platform-profile-daemon.service
sudo ./tools/dbus-smoke.sh
```

The script is opt-in and checks:

- `ActiveProfile` and `GetAll` queries
- valid `Set ActiveProfile` values (`power-saver`, `balanced`, `performance`)
- rejection of invalid profile/type/interface/path/property writes
- fixed mapping to kernel sysfs values
- restoring the original profile on exit when possible

## Security model

This daemon is designed as a minimal personal Power Profiles Daemon-compatible
bridge.

For compatibility with desktop clients and widgets, local clients are currently
allowed to read profile state over D-Bus without authorization prompts.

Mutating operations are protected with Polkit. Setting `ActiveProfile` requires
authorization for the action id:

`org.freedesktop.UPower.PowerProfiles.switch-profile`.

Requested profile names are validated strictly before authorization and sysfs
writes. Accepted values are only `power-saver`, `balanced`, and `performance`.

Read-only D-Bus operations (`Get`, `GetAll`) remain available to normal
clients.

## Manual validation checklist

```sh
# Restart service
sudo systemctl restart platform-profile-daemon.service

# Get ActiveProfile
busctl --system get-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile

# GetAll properties
busctl --system call org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.DBus.Properties GetAll s \
  org.freedesktop.UPower.PowerProfiles

# Set valid profiles
busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s power-saver
busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s balanced
busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s performance

# Set valid profile via powerprofilesctl (active local session)
powerprofilesctl set balanced

# Reject invalid profile
busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s invalid-profile

# Wrong type should fail
busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile b true

# Inspect kernel platform profile
cat /sys/firmware/acpi/platform_profile

# Check service logs
journalctl -u platform-profile-daemon.service --since "10 min ago"
```

Then verify desktop widget/client behavior by switching profiles from the UI and
confirming both D-Bus `ActiveProfile` and
`/sys/firmware/acpi/platform_profile` stay in sync.

Optional authorization validation:
- from a non-active session/user, attempt `Set ActiveProfile` and confirm it is
  denied.
- confirm `/sys/firmware/acpi/platform_profile` is unchanged on denied writes.
