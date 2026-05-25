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
- `zig build run -- --platform-profile /tmp/platform_profile`: run against a fake sysfs file. <!-- rumdl-disable-line MD013 -->
- `busctl --address="$DBUS_SESSION_BUS_ADDRESS" ...`: test D-Bus behavior inside `dbus-run-session`. <!-- rumdl-disable-line MD013 -->

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

## Testing Guidelines

Tests use Zig `test` blocks. Add focused tests near the module under test, e.g.
profile parsing in `src/profile.zig` and fake sysfs behavior in `src/sysfs.zig`.

Before handing off changes, run:

```sh
zig build test
zig build -Doptimize=ReleaseFast
```

For D-Bus changes, also run a `dbus-run-session` smoke test covering valid
profiles, invalid profiles, and same-profile no-write behavior.

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
