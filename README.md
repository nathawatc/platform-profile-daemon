# Platform Profile Daemon

Minimal Zig daemon that owns `org.freedesktop.UPower.PowerProfiles` and bridges Power Profiles Daemon-compatible D-Bus profile names to one sysfs file only:

```text
/sys/firmware/acpi/platform_profile
```

Hardcoded mapping:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

The daemon intentionally does not read `platform_profile_choices`, does not discover profiles, and does not tune CPU governors, cpufreq, amd_pstate, EPP, or vendor policy.

## Build

```sh
zig build
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
