# Repository Guidelines

## Project structure

This repository contains a minimal Zig system daemon for the Power Profiles
Daemon D-Bus API. It maps profile changes to one sysfs file:

```text
/sys/firmware/acpi/platform_profile
```

Runtime sources (`src/`):

- `main.zig`: daemon entrypoint and CLI parsing.
- `init.zig`: entrypoint of the short-lived Dynamic EPP helper that also
  reapplies the saved profile.
- `daemon.zig`: cached `ActiveProfile` state and its update rules.
- `profile.zig`: the single `Profile` enum, the fixed D-Bus/kernel mapping and
  the strict `platform_profile` parser shared by both executables.
- `sysfs.zig`: the held-open `platform_profile` file: read, fresh read, write.
- `sys.zig`: raw syscall I/O (`open`, `readOnce`, `writeAll`) with `EINTR`
  handling and errno capture; shared by both executables.
- `notify.zig`: the two `sd_notify` messages the daemon sends (`READY=1`,
  `WATCHDOG=1`) over `$NOTIFY_SOCKET`, without libsystemd.
- `rt.zig`: libc-free runtime for both executables (panic and log handlers).
- `dbus.zig`: the PowerProfiles service: properties, dispatch, signals and
  the run loop.
- `dbus/wire.zig`: D-Bus marshalling and message parsing.
- `dbus/transport.zig`: bus address, socket, SASL EXTERNAL and message framing.
- `dbus/polkit.zig`: Polkit request encoding and reply decoding.
- `dbus/introspection_{head,tail}.xml`: fixed introspection data, embedded
  with `@embedFile`. The PowerProfiles property entries are generated from
  `Prop` in `dbus.zig`.
- `testutil.zig`: test-only helpers, referenced only from `test` blocks.

Everything else:

- `build.zig`, `build.zig.zon`: build graph and package metadata.
- `data/`: systemd units, D-Bus activation/policy and Polkit policy files.
- `tools/`: install, size and smoke-test scripts (see Testing).
- `.github/workflows/ci.yml`: CI running the same checks (a `lint` job and a
  `test` job). Actions are pinned to commit SHAs (`# vN` comment);
  Dependabot proposes updates.
- `.agents/skills/zig-0-17/`: vendored Zig 0.17 guidance, pinned by
  `skills-lock.json`. Do not edit it.

> [!NOTE]
> Do not add dynamic profile discovery, read `platform_profile_choices`, or
> add extra power-management policy.

## Build

Zig 0.17.0 is required (`minimum_zig_version` in `build.zig.zon`).

```sh
zig build test                    # Debug tests, safety checks, zig fmt check
zig build                         # ReleaseSmall, the shipped build
zig build -Doptimize=ReleaseFast  # optional: faster, larger
```

`build.zig` declares `-Doptimize` itself and defaults the binaries to
ReleaseSmall (the package build). An explicit `-Doptimize` applies to the tests
too. `--release` is not used. Keep release flags in `build.zig` (LTO, section
GC, non-PIE, no unwind tables) intentional and backed by validation.

Use no deprecated Zig 0.17 APIs; consult the vendored zig-0-17 skill and
`zig env` for the std sources.

For local fake-sysfs testing:

```sh
printf 'balanced\n' > /tmp/platform_profile
zig build
sudo ./zig-out/lib/platform-profile-daemon \
    --platform-profile /tmp/platform_profile
```

Use fake sysfs for development tests. Write the real
`/sys/firmware/acpi/platform_profile` only when validating on the target
machine.

## Runtime: no libc

Both executables are static, non-PIE and libc-free. They issue raw Linux
syscalls through `std.os.linux` and decode failures with `linux.errno()`.
There is no global `errno`, so `sys.zig` helpers return `error.Sys` and store
the errno through an out-pointer for callers to map and log. Do not add
`link_libc`, `std.c`, `extern "c"`, `std.debug.print` or `std.process.exit` to
runtime code.

Each root file declares `std_options = rt.std_options` and
`panic = std.debug.FullPanic(rt.panicFn)`. `rt.zig` writes panics and log
lines straight to stderr (log lines carry an sd-daemon `<N>` priority prefix)
and traps, so std's stack-trace, debug-info and `Io.Threaded` machinery is
never linked. `main` returns a `u8` exit status instead of an error union so
`std.start` never prints an error trace. Keep stack tracing, the segfault
handler and the sigaltstack disabled. Each root also sets
`std_options_debug_threaded_io = null`, so std debug I/O fails to compile
instead of linking `Io.Threaded`.

Avoid heap allocation: buffers are fixed-size. Also avoid
`std.fmt.comptimePrint` for runtime data; it linked std's error-name table
into the binary. Plain `++` concatenation does not.

The D-Bus bus address comes from `std.process.Init.Minimal.environ`, not
`getenv`. Check release builds with `file`, `ldd` and `readelf -d` (no
`NEEDED`, no `INTERP`).

## Startup and privileges

`platform-profile-daemon-init.service` runs a separate short-lived helper
before the long-running daemon. The daemon unit uses both `Requires=` and
`After=` on the init service, so initialization failure prevents daemon
startup.

The helper reads the initial `platform_profile` and accepts only `low-power`,
`balanced` or `performance` (via `Profile.parseKernel`). Initial `custom`,
unknown, empty or malformed values fail initialization without choosing a
replacement. The helper logs `UnknownKernelProfile` for these, and
`tools/init-smoke.sh` depends on that name.

It writes `dynamic` directly to every canonical
`/sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference`, then
reapplies the saved platform profile once. Reapplication synchronizes firmware
and Dynamic EPP handlers, which may temporarily disagree during
initialization. Trust the synchronous write result: do not probe available
preferences, read EPP values or read the profile back. The target kernel must
accept `dynamic` writes; do not add support for the obsolete
`amd_dynamic_epp=enable` command-line option.

Process policy entries as encountered, without sorting or collecting names.
Keep `O_NOFOLLOW` path safety and do not use `O_NONBLOCK` for EPP writes. Zero
matching policies, disappearing or symlinked policies, symlinked EPP
attributes and failed writes fail initialization. Preserve useful path and
errno context. Already initialized policies remain changed; do not add
rollback.

The init service may write only the CPUFreq subtree and `platform_profile`
within sysfs:

```text
ReadWritePaths=/sys/devices/system/cpu/cpufreq /sys/firmware/acpi
```

The parent `/sys/firmware/acpi` directory must be granted read-write in the
init unit because writing `dynamic` to CPUFreq EPP triggers ACPI firmware
re-evaluation that can recreate or re-initialize `platform_profile`. A
single-file bind mount (`.../platform_profile`) binds to the old inode,
causing subsequent writes in the unit namespace to fail with `EROFS` against
the read-only parent sysfs mount. Other entries in `/sys/firmware/acpi` remain
protected by kernel-enforced read-only permissions (`0444`). The daemon
retains write access to `platform_profile` only. Bootstrap code must not be
linked into the daemon. Preserve filesystem and syscall hardening in both
units.

The oneshot uses `RemainAfterExit=yes`, so daemon restarts do not repeat
initialization. Do not add EPP polling, CPU hotplug management, periodic
synchronization or old-kernel fallback. Policies added afterward are not
managed. A concurrent firmware/profile change during initialization can be
overwritten when the saved initial profile is reapplied.

## Coding style

Use 4-space indentation and run `zig fmt`; `zig build test` fails on
unformatted `src/`, `build.zig` or `build.zig.zon`. Keep modules small and
direct, split by responsibility, and keep one source of truth for every fact.

- `Profile` (`profile.zig`) is the only profile type. The mapping is fixed:

  ```text
  power-saver -> low-power
  balanced    -> balanced
  performance -> performance
  ```

- `Prop` (`dbus.zig`) is the only list of D-Bus properties. Its tag names are
  the property names and it defines each type signature and writability. Get,
  GetAll, Set and the generated introspection all derive from it.
- Public Zig types use `PascalCase`; functions and fields use `camelCase`.
  `Prop` tags are the exception because they are D-Bus names.
- Prefer fixed mappings over generalized abstractions. No dead code.
- Syscall fault injection in tests uses comptime function parameters
  (`sys.readAllWith`), never runtime function pointers.
- Avoid extra sysfs I/O in D-Bus hot paths.

### State and error handling

Preserve strict runtime state semantics:

- runtime sysfs read/parse failure must not fall back to `balanced`
- invalid, empty or malformed refresh must keep cached state unchanged
- `platform_profile` is parsed in one place (`Profile.parseKernel`): an exact
  name with at most one trailing newline, no other whitespace
- the cache may update only after a valid external read or a successful sysfs
  write
- helpers must handle `EINTR`, short writes and fd cleanup; a sysfs attribute
  is read with a single `pread` because kernfs returns it whole, and a value
  that fills the buffer is malformed
- runtime code never creates files (`sys.open` rejects `CREAT` at compile time)
- expected warning noise may be suppressed in tests only, not runtime

The daemon holds `platform_profile` open read-only and polls it for
`POLLPRI | POLLERR`; each event re-reads it. Explicit requests read it through
a fresh open so they never depend on the watch fd's state.

- A failed watch read is logged and retried on the next wake. The third
  consecutive failure means the watch is lost: the daemon exits so systemd
  restarts it. Any successful read, or unusable content, resets the count.
- Handlers announce `PropertiesChanged` whenever the cached profile differs
  before and after an operation, including when it then fails. The method
  reply is sent first so a failed signal cannot swallow it.

Runtime `custom` must log a warning and preserve cached `ActiveProfile`
without writing. An explicit D-Bus `ActiveProfile` request must still write
the requested canonical profile when the kernel state is inconsistent, even if
it matches the cached value, allowing kernel handlers to converge. This also
holds when the pre-write read of `platform_profile` fails: the failure is
logged and only the write decides the outcome.

### D-Bus compatibility

Preserve desktop and widget compatibility first.

`ActiveProfile` must stay writable and emit change signals
(`EmitsChangedSignal` true in the introspection). Unprivileged callers may
reach it; authorization is decided by Polkit, not by the bus policy.

Validate before Polkit or sysfs writes:

```text
object path
interface name
property name
D-Bus type
profile value
```

Invalid input must not trigger Polkit and must not emit change signals.

Polkit is asked without blocking: a validated `Set` takes a slot in a fixed
table (`max_pending`, 8) and the main loop keeps serving the bus and the
profile watch. Verdicts are applied in the order they arrive, each reading the
kernel fresh; an unanswered request is denied after 25 s; a ninth concurrent
`Set` fails immediately. A new `Set` from a sender that already has one
pending supersedes it (the older call gets `Failed`), so one client cannot
fill the table. Do not reintroduce a nested blocking wait.

Do not add compatibility stubs for unsupported members without a demonstrated
desktop/widget compatibility need.

Authorization belongs in the handler/Polkit, not by blocking clients at the
D-Bus policy layer.

### D-Bus surface

The daemon speaks the D-Bus wire protocol natively (little-endian, SASL
EXTERNAL) and exposes:

```text
/org/freedesktop/UPower/PowerProfiles
org.freedesktop.UPower.PowerProfiles
```

Supported property operations (an empty interface name means "any" for reads;
`Set` stays strict):

```text
org.freedesktop.DBus.Properties.Get
org.freedesktop.DBus.Properties.GetAll
org.freedesktop.DBus.Properties.Set ActiveProfile
```

Also supported: `Introspect`, `Peer.Ping` and the `PropertiesChanged` signal.

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

Unsupported operations stay absent from dispatch and introspection, so D-Bus
naturally returns `UnknownMethod` or `UnknownProperty`. Do not reintroduce
stubs without a demonstrated compatibility need.

### Authorization and hardening

Only root may own the D-Bus service name. Normal desktop clients must be able
to send requests to the daemon.

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

The daemon unit is `Type=notify` with `NotifyAccess=main` and
`WatchdogSec=30s`. The daemon sends `READY=1` once it owns the bus name and a
`WATCHDOG=1` ping every 15 s from the service loop, so systemd restarts a
daemon whose loop hangs. Both are no-ops without `NOTIFY_SOCKET`, so running
the binary by hand is unchanged. A `WATCHDOG_PID` naming another process
disables the pings, as sd_watchdog_enabled(3) specifies. The service stays
resident (no idle exit): desktop widgets listen for `PropertiesChanged` and
must not miss changes.

The daemon service is hardened and only keeps write access to:

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
PrivateDevices=yes
PrivateNetwork=yes
RestrictAddressFamilies=AF_UNIX
RestrictNamespaces=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
UMask=0077
ProtectProc=invisible
IPAddressDeny=any
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
```

Both units score 0.9 in `systemd-analyze security` (`tools/check-units.sh`
gates this). Never use `ProtectKernelTunables`, `PrivateUsers`, `User=` or
`DynamicUser=` to lower the score: they break the sysfs write. Before adding
a syscall that is in `@privileged` or `@resources`, check the runtime does
not need it (trace with `strace -f`); `std.start` only calls `prlimit64`.

## Testing

Tests use Zig `test` blocks. Add focused tests near the module under test, for
example profile parsing in `src/profile.zig`, fake sysfs behavior in
`src/sysfs.zig` and message handling in `src/dbus.zig`. Use
`std.testing.tmpDir` for files, not fixed `/tmp` paths. `testutil.zig` may be
imported at file scope because unreferenced declarations are never analysed;
`tools/check-install.sh` verifies no test code reaches a binary.

Before handing off changes, run:

```sh
zig build test
zig build
bash tools/check-install.sh zig-out
bash tools/check-size.sh zig-out
bash tools/check-units.sh
bash tools/init-smoke.sh
python3 tools/capture-corpus.py --verify
bash tools/lint.sh
```

`tools/lint.sh` is the single lint entrypoint, also run by the CI `lint` job:
`zig fmt --check`, `shellcheck`, `shfmt -i 0 -sr -ci -bn`, `ruff check` and
`ruff format --check` (Python tools), and `rumdl check .`. Install `shellcheck`,
`shfmt`, `ruff` and `rumdl` locally; CI pins `ruff` and `rumdl` versions in
`ci.yml`, so bump them there together with any new findings.

`tools/check-size.sh` enforces the binary size budgets and
`tools/check-units.sh` the unit exposure scores. The init smoke test
uses unprivileged user and mount namespaces. For D-Bus changes also run the
isolated smoke test, which uses a private bus, fake sysfs and a test Polkit
responder (needs `python-gobject`; run after a plain `zig build`):

```sh
unshare --user --map-root-user python3 tools/dbus-isolated-smoke.py
```

The code that reads bytes from the bus (`dbus/wire.zig`, framing and SASL in
`dbus/transport.zig`, `decide` in `dbus/polkit.zig`) has fuzz tests. Plain
`zig build test` replays deterministic sweeps; explore further with a bounded
session (fuzzing needs the LLVM backend):

```sh
zig build test --fuzz=500K -Dllvm=true
```

Keep new byte-parsing code covered the same way.

`src/dbus/testdata/` holds real frames captured from sd-bus (`busctl`), GDBus
(the fake Polkit responder) and dbus-daemon, plus the daemon's own replies and
signals. The parser and framing tests replay them, including mutation and
chunking sweeps. `frames.zig` and the `.bin` files are generated; regenerate
them when the protocol surface changes and never edit them by hand:

```sh
CAPTURE_PCAP=/tmp/ppd.pcap unshare --user --map-root-user \
    python3 tools/dbus-isolated-smoke.py
python3 tools/capture-corpus.py /tmp/ppd.pcap
```

Regeneration always shows a diff (serials and unique bus names vary), so
review it. The script refuses frames whose header names fall outside an
allowlist or whose body text looks like a home or temp path or the user or
host name. `python3 tools/capture-corpus.py --verify` re-checks the committed
corpus and that `frames.zig` matches the `.bin` files; CI runs it.

For D-Bus, service or authorization changes, also run the system-bus smoke
test on a root/systemd target:

```sh
sudo ./tools/dbus-smoke.sh
```

Sandbox directives cannot be exercised without systemd, so after changing a
unit also run on the target machine:

```sh
sudo systemctl daemon-reload
sudo systemctl restart platform-profile-daemon-init platform-profile-daemon
systemctl status platform-profile-daemon       # active, started via READY=1
journalctl -u platform-profile-daemon -b       # no seccomp (SIGSYS) kills
systemd-analyze security platform-profile-daemon.service
```

To exercise the watchdog, `sudo kill -STOP` the daemon: systemd restarts it
after about 30 s ("Watchdog timeout" in the journal).

The smoke test should cover reads, writes, invalid input rejection, mapping
correctness and same-profile no-write behavior. Against the real sysfs it also
writes a different profile straight into `platform_profile` and requires the
daemon to follow it and emit `PropertiesChanged` (skip with
`SKIP_EXTERNAL=1`). Fake files cannot produce `POLLPRI`, so the isolated smoke
test never runs that check; the loop wiring is unit-tested with an injected
poll function, so a prompt open in Polkit cannot starve the watch.

## Commit and PR

Use the existing conventional style:

```text
feat(dbus): ...
fix(daemon): ...
perf(dbus): ...
refactor(profile): ...
test: ...
```

Pull requests should describe why the change is needed, what sysfs/D-Bus
behavior changed and how it was validated. Include command output summaries
for build, tests and smoke checks. Note explicitly if a change affects the
strict sysfs-only contract.

Markdown files must pass `rumdl check .` (part of `tools/lint.sh`); the config
in `.rumdl.toml` excludes the vendored skills.

## Release

Releases are tagged `vX.Y.Z`; `build.zig.zon` `.version` must equal the tag.
Before tagging:

1. CI is green on `main` (`lint` and `test` jobs).
2. Run the full list under Testing on the final commit.
3. Run the target-machine checklist under Testing on a real systemd
   machine; sandbox directives, the real-sysfs external-change check and the
   watchdog cannot be verified anywhere else.
4. Update user-facing behavior in `README.md` and summarize the behavior
   changes since the last tag in the release notes: reply order, exit policy,
   Polkit handling, unit hardening, anything that changes what users see.

The packaged build is `ReleaseSmall`; validate against it, not only
`ReleaseFast`.

## Security and scope

The daemon must not manage:

```text
EPP
cpufreq
CPU governors
vendor tuning
policy engines
```

The separate init helper is the sole exception: it writes `dynamic` to
canonical CPUFreq policy EPP attributes once, then reapplies the saved
supported platform profile. Keep bootstrap code and CPUFreq permissions out of
the daemon. Initial `custom` is fatal; runtime `custom` preserves cache
without writing.

The daemon may only read and write:

```text
/sys/firmware/acpi/platform_profile
```

Do not add shell execution to daemon runtime. Do not make the service
root-only at the bus-policy layer. Do not block normal clients from sending
requests to:

```text
org.freedesktop.UPower.PowerProfiles
```

When touching service or install behavior, verify:

- systemd hardening still permits only the required sysfs writes
  (`/sys/devices/system/cpu/cpufreq` and `/sys/firmware/acpi` for init,
  `/sys/firmware/acpi/platform_profile` for daemon)
- the unit does not combine `Conflicts=power-profiles-daemon.service` with
  `Alias=power-profiles-daemon.service`
- installed service, D-Bus and Polkit files are 0644
- no script copies staged `/usr` trees with `cp -a` or changes ownership of
  system directories
