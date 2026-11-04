# Contributing

Thanks for helping improve `platform-profile-daemon`.

The project is intentionally small: a Power Profiles Daemon-compatible D-Bus
service backed only by `/sys/firmware/acpi/platform_profile`. Read
[README.md](README.md) for what it does and [AGENTS.md](AGENTS.md) for the
developer rules: architecture, D-Bus compatibility, security scope and testing
details.

## Scope

Accepted changes keep the fixed mapping:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

The separate init helper enables Dynamic EPP once and reapplies the saved
profile; its CPUFreq permissions stay out of the daemon. Do not add CPU
governors, static EPP, TLP, vendor tuning, `platform_profile_choices`
discovery or policy-engine behavior.

Preserve desktop compatibility:

- `ActiveProfile` stays writable by normal desktop clients
- invalid input is rejected before authorization or sysfs writes
- failed or denied writes never emit profile-change signals
- runtime sysfs failures never turn into a fake `balanced`

## Setup

You need Zig 0.17.0. Use a fake sysfs file for development:

```sh
printf 'balanced\n' > /tmp/platform_profile
zig build
sudo ./zig-out/lib/platform-profile-daemon \
    --platform-profile /tmp/platform_profile
```

Do not write the real `/sys/firmware/acpi/platform_profile` unless you are
validating on a target machine.

## Checks

Run before submitting:

```sh
zig build test                      # tests plus the zig fmt check
zig build
bash tools/check-install.sh zig-out
bash tools/check-size.sh zig-out
bash tools/check-units.sh
bash tools/init-smoke.sh
unshare --user --map-root-user python3 tools/dbus-isolated-smoke.py
python3 tools/capture-corpus.py --verify
bash tools/lint.sh
```

`tools/lint.sh` needs `shellcheck`, `shfmt`, `ruff` and `rumdl`. The isolated
D-Bus smoke test needs `python-gobject`, `dbus-daemon` and `unshare`. CI runs
the same checks in a `lint` job and a `test` job.

These checks do not replace validation on a real systemd machine. For D-Bus,
service, unit or authorization changes, also run on a target:

```sh
sudo systemctl daemon-reload
sudo systemctl restart platform-profile-daemon-init platform-profile-daemon
systemctl status platform-profile-daemon   # active, started via READY=1
journalctl -u platform-profile-daemon -b   # no seccomp (SIGSYS) kills
sudo ./tools/dbus-smoke.sh
systemd-analyze security platform-profile-daemon.service
```

Then switch profiles from the desktop widget. To check the watchdog,
`sudo kill -STOP` the daemon: systemd restarts it after about 30 s.

Fuzzing and corpus regeneration are described in the Testing section of
AGENTS.md.

## Commits and pull requests

Use conventional commits:

```text
feat(dbus): ...
fix(daemon): ...
perf(dbus): ...
refactor(profile): ...
test: ...
```

A pull request should say why the change is needed, what sysfs or D-Bus
behavior changed, how you validated it (with command output summaries), and
whether the strict sysfs-only contract changed. If it touches packaging,
service files, D-Bus policy or Polkit policy, include installed-system
validation results.

Markdown must pass `rumdl check .` (80 columns).
