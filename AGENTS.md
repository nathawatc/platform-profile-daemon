# Repository Guidelines

## Project structure

This repository contains a minimal Zig system daemon for the Power Profiles
Daemon D-Bus API. It maps profile changes to one sysfs file:

```text
/sys/firmware/acpi/platform_profile
```

- `src/main.zig`: process entrypoint, CLI parsing, C shim exports.
- `src/daemon.zig`: cached daemon state and profile-change orchestration.
- `src/profile.zig`: fixed D-Bus/kernel profile mapping.
- `src/sysfs.zig`: direct sysfs read/write helpers.
- `src/dbus_shim.c`: `sd-bus` service, properties, methods, and signals.
- `data/`: systemd unit, D-Bus activation/policy, and Polkit policy files.
- `packaging/arch/`: Arch packaging metadata.

> [!NOTE]
> Do not add dynamic profile discovery, read `platform_profile_choices`, or add
> extra power-management policy.

## Build

```sh
zig build test
zig build -Doptimize=ReleaseFast
```

For local fake-sysfs testing:

```sh
printf 'balanced\n' > /tmp/platform_profile
zig build -Doptimize=ReleaseFast
sudo ./zig-out/bin/platform-profile-daemon --platform-profile /tmp/platform_profile
```

Use fake sysfs for development tests. Write the real
`/sys/firmware/acpi/platform_profile` only when validating on the target machine.

## Coding style

Use 4-space indentation for Zig and C. Keep modules small and direct.

Prefer fixed mappings over generalized abstractions:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

Public Zig types use `PascalCase`. Zig functions and fields use `camelCase`.
C helpers use `snake_case`.

Avoid hidden allocations and avoid extra sysfs I/O in D-Bus hot paths. Keep
release-oriented build flags in `build.zig` intentional and backed by validation.

### State and error handling

Preserve strict runtime state semantics:

- runtime sysfs read/parse failure must not fall back to `balanced`
- invalid, empty, or malformed refresh must keep cached state unchanged
- cache may update only after a valid external read or successful sysfs write
- read/write helpers must handle `EINTR`, short reads/writes, and fd cleanup
- expected warning noise may be suppressed in tests only, not runtime

### D-Bus compatibility

Preserve desktop and widget compatibility first.

`ActiveProfile` must stay writable with:

```text
SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE
SD_BUS_VTABLE_UNPRIVILEGED
```

Validate before Polkit or sysfs writes:

```text
object path
interface name
property name
D-Bus type
profile value
```

Invalid input must not trigger Polkit and must not emit change signals.

Do not add compatibility stubs for unsupported members without a demonstrated
desktop/widget compatibility need.

Authorization belongs in the handler/Polkit, not by blocking clients at the
D-Bus policy layer.

### D-Bus surface

The daemon exposes:

```text
/org/freedesktop/UPower/PowerProfiles
org.freedesktop.UPower.PowerProfiles
```

Supported property operations:

```text
org.freedesktop.DBus.Properties.Get
org.freedesktop.DBus.Properties.GetAll
org.freedesktop.DBus.Properties.Set ActiveProfile
```

The D-Bus surface intentionally retains these properties:

```text
ActiveProfile
PerformanceDegraded
Profiles
Actions
ActionsInfo
ActiveProfileHolds
Version
```

Unsupported operations stay absent from the vtable and introspection, so D-Bus
naturally returns `UnknownMethod` or `UnknownProperty`. Do not reintroduce stubs
without a demonstrated compatibility need.

### Authorization and hardening

Only root may own the D-Bus service name. Normal desktop clients must be able to
send requests to the daemon.

The Polkit action used for profile switching is:

```text
net.hadess.PowerProfiles.switch-profile
```

A compatibility action is also installed:

```text
org.freedesktop.UPower.PowerProfiles.switch-profile
```

Active local sessions are allowed by default. Inactive or remote sessions are
denied unless local Polkit policy changes that.

The systemd service is hardened and only keeps write access to:

```text
/sys/firmware/acpi/platform_profile
```

Relevant hardening options include:

```text
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
ReadWritePaths=/sys/firmware/acpi/platform_profile
RestrictAddressFamilies=AF_UNIX
SystemCallFilter=@system-service
```

## Testing

Tests use Zig `test` blocks. Add focused tests near the module under test, for
example profile parsing in `src/profile.zig` and fake sysfs behavior in
`src/sysfs.zig`.

Before handing off changes, run:

```sh
zig build test
zig build -Doptimize=ReleaseFast
```

For D-Bus changes, run the system-bus smoke test on a root/systemd target:

```sh
sudo ./tools/dbus-smoke.sh
```

The smoke test should cover reads, writes, invalid input rejection, mapping
correctness, and same-profile no-write behavior.

## Commit and PR

Use the existing conventional style:

```text
feat(dbus): ...
fix(daemon): ...
perf(dbus): ...
refactor(profile): ...
```

Pull requests should describe why the change is needed, what sysfs/D-Bus
behavior changed, and how it was validated. Include command output summaries for
build, tests, and D-Bus smoke checks. Note explicitly if a change affects the
strict sysfs-only contract.

## Security and scope

The daemon must not manage:

```text
EPP
cpufreq
CPU governors
vendor tuning
policy engines
```

It may only read and write:

```text
/sys/firmware/acpi/platform_profile
```

Do not add shell execution to daemon runtime. Do not make the service root-only
at the bus-policy layer. Do not block normal clients from sending requests to:

```text
org.freedesktop.UPower.PowerProfiles
```

When touching service or install behavior, verify:

- systemd hardening still permits only the required sysfs write
- the unit does not combine `Conflicts=power-profiles-daemon.service` with
  `Alias=power-profiles-daemon.service`
- installed service, D-Bus, and Polkit files are 0644
- no script copies staged `/usr` trees with `cp -a` or changes ownership of
  system directories
