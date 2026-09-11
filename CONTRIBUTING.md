# Contributing

Thanks for helping improve `platform-profile-daemon`.

This project is intentionally small: it implements a Power Profiles
Daemon-compatible D-Bus service backed only by:

```text
/sys/firmware/acpi/platform_profile
```

Before changing behavior, read:

- `README.md` for user-facing behavior and manual validation
- `AGENTS.md` for developer rules, D-Bus compatibility, security scope, and
  review requirements

## Scope

Accepted changes should preserve the fixed mapping:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

The separate init helper opts canonical CPUFreq policies into Dynamic EPP once
and reapplies the saved platform profile. Keep that code and its CPUFreq write
permissions out of the long-running daemon. Do not add CPU governor, static EPP,
TLP, vendor tuning, `platform_profile_choices` discovery, or policy-engine behavior.

## Development

Use fake sysfs for local development:

```sh
printf 'balanced\n' > /tmp/platform_profile
zig build -Doptimize=ReleaseFast
sudo ./zig-out/lib/platform-profile-daemon --platform-profile /tmp/platform_profile
```

Do not write the real `/sys/firmware/acpi/platform_profile` unless intentionally
validating on a target machine.

## Required checks

Run before submitting changes:

```sh
zig build test
zig build -Doptimize=ReleaseFast
zig fmt --check build.zig build.zig.zon src/*.zig
bash tools/check-install.sh zig-out
bash tools/init-smoke.sh
```

The init smoke test uses unprivileged user/mount namespaces and a temporary
sysfs tree. An optional isolated D-Bus check also runs the existing smoke suite
with fake sysfs and a test Polkit responder (requires `python-gobject`):

```sh
unshare --user --map-root-user python3 tools/dbus-isolated-smoke.py
```

These checks do not replace target systemd sandbox and real Polkit validation.
Before publishing an Arch release, replace the development `SKIP` checksum with
the released archive's BLAKE2 checksum and regenerate `.SRCINFO`.

For D-Bus, service, or authorization changes, also run on a target machine:

```sh
sudo systemctl restart platform-profile-daemon.service
sudo ./tools/dbus-smoke.sh
```

Then verify desktop widget or power-menu switching still works.

## Compatibility rules

Preserve desktop/client compatibility:

- `ActiveProfile` must remain writable by normal desktop clients
- invalid input must be rejected before authorization or sysfs writes
- failed or denied writes must not emit fake profile-change signals
- compatibility properties and methods must not be removed without a specific
  compatibility audit

Runtime sysfs failures must stay strict:

- invalid, empty, or malformed refreshes must not become fake `balanced`
- cached state may update only after a valid read or successful write

## Pull requests

Use the existing commit style:

```text
feat(dbus): ...
fix(daemon): ...
perf(dbus): ...
refactor(profile): ...
```

Pull requests should include:

- why the change is needed
- what sysfs or D-Bus behavior changed
- validation commands and result summaries
- whether the strict sysfs-only contract changed

If a change touches packaging, service files, D-Bus policy, or Polkit policy,
include the relevant installed-system validation results.
