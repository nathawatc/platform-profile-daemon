# Platform Profile Daemon

Minimal Zig system daemon that owns `org.freedesktop.UPower.PowerProfiles` and
bridges Power Profiles Daemon-compatible D-Bus profile names to one sysfs file:

```text
/sys/firmware/acpi/platform_profile
```

Fixed mapping:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

The daemon intentionally does not read `platform_profile_choices`, discover
profiles, tune CPU governors, change cpufreq, manage amd_pstate/EPP, integrate
with TLP, or implement vendor policy. It only reads and writes the kernel
`platform_profile` attribute.

## Runtime Model

The installed daemon is systemd-managed and D-Bus activated.

```text
desktop client -> org.freedesktop.UPower.PowerProfiles
               -> platform-profile-daemon
               -> /sys/firmware/acpi/platform_profile
```

Do not normally run `/usr/bin/platform-profile-daemon` manually. The packaged
binary is installed as `/usr/lib/platform-profile-daemon`, and the systemd unit
owns the system-bus name `org.freedesktop.UPower.PowerProfiles`.

The `--platform-profile PATH` option exists for local fake-sysfs testing. The
installed service does not use it.

## Build And Test

```sh
zig build test
zig build -Doptimize=ReleaseFast
```

## Fake Sysfs Test

This is only for local development:

```sh
printf 'balanced\n' > /tmp/platform_profile
zig build -Doptimize=ReleaseFast
sudo ./zig-out/bin/platform-profile-daemon --platform-profile /tmp/platform_profile
```

Use fake sysfs files for local tests. Do not write the real
`/sys/firmware/acpi/platform_profile` unless intentionally validating on a
target machine.

## D-Bus API

The daemon exposes:

```text
/org/freedesktop/UPower/PowerProfiles
org.freedesktop.UPower.PowerProfiles
org.freedesktop.DBus.Properties.Get
org.freedesktop.DBus.Properties.GetAll
org.freedesktop.DBus.Properties.Set ActiveProfile
```

Compatibility properties and methods are present for desktop clients that probe
Power Profiles Daemon:

```text
PerformanceInhibited
PerformanceDegraded
Profiles
Actions
ActionsInfo
ActiveProfileHolds
Version
BatteryAware
HoldProfile
ReleaseProfile
SetActionEnabled
```

Unsupported compatibility stubs return empty/default state or explicit
`NotSupported`/`InvalidArgs` errors instead of implementing extra policy.

## Security Model

The D-Bus policy allows normal clients to send requests to the daemon while only
root may own `org.freedesktop.UPower.PowerProfiles`. Mutating authorization is
done in the handler, not by making the D-Bus service root-only.

Setting `ActiveProfile` validates object path, interface, property name, D-Bus
type, and requested profile before any Polkit check or sysfs write.

The runtime Polkit action is:

```text
net.hadess.PowerProfiles.switch-profile
```

The policy file also installs
`org.freedesktop.UPower.PowerProfiles.switch-profile` as a compatibility action
for local rules from older builds. Active local sessions are allowed by default;
inactive or remote sessions are denied unless local policy changes that.

The systemd unit keeps the daemon constrained with:

```text
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
ReadWritePaths=/sys/firmware/acpi/platform_profile
RestrictAddressFamilies=AF_UNIX
SystemCallFilter=@system-service
```

## Manual Validation

Run on a target machine with systemd, a system bus, and writable
`/sys/firmware/acpi/platform_profile`:

```sh
sudo systemctl restart platform-profile-daemon.service
busctl --system status org.freedesktop.UPower.PowerProfiles
powerprofilesctl get
powerprofilesctl set power-saver
cat /sys/firmware/acpi/platform_profile
powerprofilesctl set balanced
cat /sys/firmware/acpi/platform_profile
powerprofilesctl set performance
cat /sys/firmware/acpi/platform_profile
sudo ./tools/dbus-smoke.sh
```

The smoke test checks `ActiveProfile`, `Profiles`, `GetAll`, valid profile
writes, invalid profile/type/interface/path/property rejection, kernel mapping,
and best-effort restoration of the original profile.

After CLI validation, switch profiles from the desktop widget or power menu and
confirm D-Bus `ActiveProfile` and
`/sys/firmware/acpi/platform_profile` stay in sync.

## Troubleshooting

`Permission denied` when started as a normal user:
Run the systemd service instead. The daemon writes sysfs and is intended to run
as root under systemd hardening.

`File exists` or name-acquisition failure:
Another daemon, usually `power-profiles-daemon.service`, already owns
`org.freedesktop.UPower.PowerProfiles`. Stop the other daemon before starting
this one.

`AccessDenied` from desktop clients:
Check that `ActiveProfile` still has `SD_BUS_VTABLE_UNPRIVILEGED`, that the
D-Bus policy allows sends to `org.freedesktop.UPower.PowerProfiles`, and that
the installed Polkit policy exposes `net.hadess.PowerProfiles.switch-profile`.
Use `pkaction --verbose` after installing the policy; source-tree edits do not
change the live Polkit database.

Unknown or empty `ActiveProfile` at startup:
The current kernel value must be one of `low-power`, `balanced`, or
`performance`. Invalid, empty, or malformed runtime refreshes are ignored and do
not become fake `balanced` changes.
