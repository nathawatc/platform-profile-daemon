# Repository Guidelines

## Project structure

This repository contains a minimal Zig system daemon for the Power Profiles
Daemon D-Bus API. It maps profile changes to one sysfs file:

```text
/sys/firmware/acpi/platform_profile
```

- `src/main.zig`: process entrypoint and CLI parsing.
- `src/init.zig`: short-lived Dynamic EPP initialization and saved profile reapplication.
- `src/daemon.zig`: cached daemon state and profile-change orchestration.
- `src/profile.zig`: the single `Profile` enum, fixed D-Bus/kernel mapping and the
  strict `platform_profile` parser shared by both executables.
- `src/sysfs.zig`: the held-open `platform_profile` file: read, fresh read, write.
- `src/sys.zig`: raw syscall I/O (`open`, `readAll`, `writeAll`) with `EINTR` and
  short-transfer handling and errno capture; shared by both executables.
- `src/rt.zig`: libc-free runtime shared by both executables (panic and log handlers).
- `src/testutil.zig`: test-only helpers; never imported by runtime code.
- `src/dbus.zig`: the PowerProfiles service: properties, dispatch, signals, run loop.
- `src/dbus/wire.zig`: D-Bus marshalling and message parsing.
- `src/dbus/transport.zig`: bus address, socket, SASL EXTERNAL, message framing.
- `src/dbus/polkit.zig`: Polkit request encoding and reply decoding.
- `src/dbus/introspection.xml`: introspection data, embedded with `@embedFile`.
- `data/`: systemd unit, D-Bus activation/policy, and Polkit policy files.

> [!NOTE]
> Do not add dynamic profile discovery, read `platform_profile_choices`, or add
> extra power-management policy.

## Build

```sh
zig build test                        # Debug tests, safety checks on
zig build                             # ReleaseSmall, the shipped build
zig build -Doptimize=ReleaseFast      # optional: faster, larger
```

`build.zig` declares `-Doptimize` itself and defaults the binaries to
ReleaseSmall (the package build). An explicit `-Doptimize` applies to the
tests too. `--release` is not used.

For local fake-sysfs testing:

```sh
printf 'balanced\n' > /tmp/platform_profile
zig build
sudo ./zig-out/lib/platform-profile-daemon --platform-profile /tmp/platform_profile
```

Use fake sysfs for development tests. Write the real
`/sys/firmware/acpi/platform_profile` only when validating on the target machine.

## Runtime: no libc

Both executables are static, non-PIE and libc-free. They issue raw Linux
syscalls through `std.os.linux` and decode failures with `linux.errno()`; there
is no global `errno`, so `sys.zig` helpers return `error.Sys` and store the errno
through an out-pointer for callers to map and log. Do not add `link_libc`, `std.c`, `extern
"c"`, `std.debug.print`, or `std.process.exit` to runtime code.

Each root file declares `std_options = rt.std_options` and
`panic = std.debug.FullPanic(rt.panicFn)`. `rt.zig` writes panics and log lines
straight to stderr (log lines carry an sd-daemon `<N>` priority prefix) and
traps, so std's stack-trace, debug-info and `Io.Threaded` machinery is never
linked. `main` returns a `u8` exit status instead of an error union so
`std.start` never prints an error trace. Keep stack tracing, the segfault
handler and the sigaltstack disabled. Each root also sets
`std_options_debug_threaded_io = null`, so std debug I/O (`std.debug.print`,
`lockStderr`) fails to compile instead of linking `Io.Threaded`.

The D-Bus bus address comes from `std.process.Init.Minimal.environ`, not
`getenv`. Release builds use `pie = false` and section GC; check the result
with `file`, `ldd` and `readelf -d` (no `NEEDED`, no `INTERP`).

## Startup and privileges

`platform-profile-daemon-init.service` runs a separate short-lived helper before
the long-running daemon. The daemon unit uses both `Requires=` and `After=` on
the init service, so initialization failure prevents daemon startup.

The helper reads the initial `platform_profile` and accepts only `low-power`,
`balanced`, or `performance`. Initial `custom`, unknown, empty, or malformed
values fail initialization without choosing a replacement.

It writes `dynamic` directly to every canonical
`/sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference`, then
reapplies the saved platform profile once. Reapplication synchronizes firmware
and Dynamic EPP handlers, which may temporarily disagree during initialization.
Trust the synchronous write result: do not probe available preferences, read EPP
values, or read the profile back. The target kernel must accept `dynamic` writes;
do not add support for the obsolete `amd_dynamic_epp=enable` command-line option.

Process policy entries as encountered, without sorting or collecting names.
Keep `O_NOFOLLOW` path safety and do not use `O_NONBLOCK` for EPP writes. Zero
matching policies, disappearing or symlinked policies, symlinked EPP attributes,
and failed writes fail initialization. Preserve useful path and errno context.
Already initialized policies remain changed; do not add rollback.

The init service may write only the CPUFreq subtree and `platform_profile`
within sysfs (`ReadWritePaths=/sys/devices/system/cpu/cpufreq /sys/firmware/acpi`).
The parent `/sys/firmware/acpi` directory must be granted read-write in the init
unit because writing `dynamic` to CPUFreq EPP triggers ACPI firmware re-evaluation
that can recreate or re-initialize `platform_profile`. A single-file bind mount
(`.../platform_profile`) binds to the old inode, causing subsequent writes in
the unit namespace to fail with `EROFS` against the read-only parent sysfs mount.
Other entries in `/sys/firmware/acpi` remain protected by kernel-enforced read-only
permissions (`0444`). The daemon retains write access to `platform_profile`.
Bootstrap code must not be linked into the daemon. Preserve filesystem and
syscall hardening in both units.

The oneshot uses `RemainAfterExit=yes`, so daemon restarts do not repeat
initialization. Do not add EPP polling, CPU hotplug management, periodic
synchronization, or old-kernel fallback. Policies added afterward are not
managed. A concurrent firmware/profile change during initialization can be
overwritten when the saved initial profile is reapplied.

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
- `platform_profile` is parsed in one place (`Profile.parseKernel`): an exact
  name with at most one trailing newline, no other whitespace
- a failed read of the watched fd is logged and retried on the next wake; the
  third consecutive failure means the watch is lost and the daemon exits so
  systemd restarts it, instead of continuing without change events
- the watch fd is also serviced while a Polkit reply is awaited
- handlers announce `PropertiesChanged` whenever the cached profile differs
  before and after an operation, including when it then fails; the method
  reply is sent first so a failed signal cannot swallow it
- cache may update only after a valid external read or successful sysfs write
- read/write helpers must handle `EINTR`, short reads/writes, and fd cleanup
- expected warning noise may be suppressed in tests only, not runtime

Runtime `custom` must log a warning and preserve cached `ActiveProfile` without
writing. An explicit D-Bus `ActiveProfile` request must still write the requested
canonical profile when the kernel state is inconsistent, even if it matches the
cached value, allowing kernel handlers to converge. This also holds when the
pre-write read of `platform_profile` fails: the failure is logged and only the
write decides the outcome.

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
zig build
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

The separate v1.1.0 init helper is the sole exception: it writes `dynamic` to
canonical CPUFreq policy EPP attributes once, then reapplies the saved supported
platform profile. Keep bootstrap code and CPUFreq permissions out of the daemon.
Initial `custom` is fatal; runtime `custom` preserves cache without writing.

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

- systemd hardening still permits only the required sysfs writes
  (`/sys/devices/system/cpu/cpufreq` and `/sys/firmware/acpi` for init,
  `/sys/firmware/acpi/platform_profile` for daemon)
- the unit does not combine `Conflicts=power-profiles-daemon.service` with
  `Alias=power-profiles-daemon.service`
- installed service, D-Bus, and Polkit files are 0644
- no script copies staged `/usr` trees with `cp -a` or changes ownership of
  system directories
