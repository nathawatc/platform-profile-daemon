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
zig build run -- --platform-profile /tmp/platform_profile
```

## Query

```sh
busctl get-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile
```
