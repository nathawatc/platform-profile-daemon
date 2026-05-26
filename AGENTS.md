# Repository Guidelines

## Project Structure & Module Organization

This repository contains a minimal Zig system daemon that exposes a Power
Profiles Daemon-compatible D-Bus API while touching only
`/sys/firmware/acpi/platform_profile`.

- `src/main.zig`: process entrypoint, CLI argument parsing, C shim exports.
- `src/daemon.zig`: cached daemon state and profile-change orchestration.
- `src/profile.zig`: hardcoded D-Bus/kernel profile mapping.
- `src/sysfs.zig`: direct sysfs read/write helpers.
- `src/dbus_shim.c`: `sd-bus` service, properties, methods, and signals.
- `data/`: systemd unit and D-Bus activation/policy files.
- `packaging/arch/`: Arch packaging metadata.

Do not add dynamic profile discovery or read `platform_profile_choices`.

## Build, Test, and Development Commands

- `zig build test`: run Zig unit tests.
- `zig build -Doptimize=ReleaseFast`: build the optimized daemon.
- `sudo ./zig-out/bin/platform-profile-daemon --platform-profile /tmp/platform_profile`: run against a fake sysfs file (system bus). <!-- rumdl-disable-line MD013 -->
- `busctl --system ...`: test D-Bus behavior on the system bus. <!-- rumdl-disable-line MD013 -->

Use fake sysfs files for local tests. Do not write real
`/sys/firmware/acpi/platform_profile` unless intentionally testing on a target
machine.

## Coding Style & Naming Conventions

Use 4-space indentation for Zig and C. Keep modules small and direct. Prefer
explicit fixed mappings over generalized abstractions. Public Zig types use
`PascalCase`; functions and fields use `camelCase`. C helpers use `snake_case`.

Avoid hidden allocations and avoid extra sysfs I/O in D-Bus hot paths. Keep
release-oriented build flags in `build.zig` intentional and documented by
validation.

Keep error paths explicit and preserve strict state semantics:

- runtime sysfs read/parse failure must not fall back to `balanced`;
- invalid/empty/malformed refresh must keep cached state unchanged;
- cache may update only after a valid external read or successful sysfs write;
- read/write helpers must handle `EINTR`, short reads/writes, and fd cleanup;
- expected warning noise may be suppressed in tests only, not runtime.

For D-Bus changes, preserve desktop/widget compatibility first:

- `ActiveProfile` must stay writable with `SD_BUS_VTABLE_UNPRIVILEGED`;
- validate object path, interface, property, type, and profile before Polkit or
  sysfs writes;
- invalid input must not trigger Polkit and must not emit change signals;
- keep compatibility stubs unless they are proven unused and outside the PPD
  compatibility surface;
- authorization belongs in the handler/Polkit, not by blocking clients at the
  D-Bus policy layer.

## Testing Guidelines

Tests use Zig `test` blocks. Add focused tests near the module under test, e.g.
profile parsing in `src/profile.zig` and fake sysfs behavior in `src/sysfs.zig`.

Before handing off changes, run:

```sh
zig build test
zig build -Doptimize=ReleaseFast
```

For D-Bus changes, run a system-bus smoke test (root/systemd environment)
covering valid profiles, invalid profiles, and same-profile no-write behavior.

## Commit & Pull Request Guidelines

Follow the existing conventional style: `feat(dbus): ...`, `fix(daemon): ...`,
`perf(dbus): ...`, `refactor(profile): ...`.

Pull requests should describe why the change is needed, what sysfs/D-Bus
behavior changed, and how it was validated. Include command output summaries for
build, tests, and D-Bus smoke checks. Note explicitly if a change affects the
strict sysfs-only contract.

## Security & Scope Rules

The daemon must not manage EPP, cpufreq, CPU governors, vendor tuning, or policy
engines. It may only read and write `/sys/firmware/acpi/platform_profile`.

Do not add shell execution to daemon runtime. Do not make the service root-only
at the bus-policy layer. Do not block normal clients from sending requests to
`org.freedesktop.UPower.PowerProfiles`.

When touching service or install behavior, verify:

- systemd hardening still permits only the required sysfs write;
- the unit does not combine `Conflicts=power-profiles-daemon.service` with
  `Alias=power-profiles-daemon.service`;
- installed service, D-Bus, and Polkit files are 0644;
- no script copies staged `/usr` trees with `cp -a` or changes ownership of
  system directories.
