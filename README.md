# Platform Profile Daemon

A tiny Power Profiles Daemon-compatible service for Linux 7.3.0-rc1+ with
Dynamic EPP. Desktop power controls (GNOME, KDE, widgets) switch the kernel
platform profile through it:

```text
/sys/firmware/acpi/platform_profile
```

It does not manage CPU governors, static EPP, TLP or vendor tuning.

Fixed mapping:

```text
power-saver -> low-power
balanced    -> balanced
performance -> performance
```

> [!NOTE]
> The project is intentionally small. It does not discover profiles from
> `platform_profile_choices`; it only supports the mapping above.

## How it works

Two systemd services are installed:

- `platform-profile-daemon-init.service` runs once at boot. It enables
  Dynamic EPP (`dynamic` in every CPUFreq policy's
  `energy_performance_preference`) and reapplies your saved platform profile.
  The `amd_dynamic_epp=enable` kernel option is neither needed nor supported.
- `platform-profile-daemon.service` stays running. It owns the D-Bus name
  `org.freedesktop.UPower.PowerProfiles`, answers desktop requests, asks
  Polkit before changing the profile, and follows changes made elsewhere
  (for example by firmware hotkeys), announcing them on D-Bus.

The daemon is a static, libc-free binary of about 27 KB. Its unit is
sandboxed: it can write only `platform_profile`, has no capabilities and no
network. It reports readiness to systemd and pings the systemd watchdog, so a
hung daemon is restarted automatically within about 30 seconds.

See [AGENTS.md](AGENTS.md) for the technical details.

## Install

### Arch Linux (AUR)

```sh
paru -S platform-profile-daemon
sudo systemctl enable --now platform-profile-daemon.service
```

The package installs both executables, both systemd units, the D-Bus
policy and activation files, and the Polkit policy. Enable only the main
service; it starts the init service first.

### Manual installation

Zig 0.17.0 is required. The shipped build is `ReleaseSmall`, the default:

```sh
DESTDIR="$PWD/stage" zig build install --prefix /usr
```

Copy the staged files into place with these permissions: executables `0755`,
systemd, D-Bus and Polkit files `0644`. Then reload systemd and enable only
the main service:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now platform-profile-daemon.service
```

## Use

Use your desktop's power menu or widget. From a terminal:

```sh
busctl --system get-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile

busctl --system set-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles \
  org.freedesktop.UPower.PowerProfiles ActiveProfile s performance

cat /sys/firmware/acpi/platform_profile
```

Active local sessions may switch profiles without a password. Inactive or
remote sessions are denied unless your Polkit policy says otherwise (action
`net.hadess.PowerProfiles.switch-profile`).

## Verify an installation

```sh
systemctl status platform-profile-daemon.service      # active (running)
busctl --system status org.freedesktop.UPower.PowerProfiles
journalctl -u platform-profile-daemon.service -b      # no errors
sudo ./tools/dbus-smoke.sh                            # optional full check
```

The smoke test switches every profile, checks that invalid requests are
rejected, and (on the real sysfs) checks that a change written straight into
`platform_profile` shows up on D-Bus.

## Troubleshooting

### Initialization fails

```sh
journalctl -u platform-profile-daemon-init.service -b
```

The saved initial profile must be `low-power`, `balanced` or `performance`.
`custom`, unknown or empty values stop initialization on purpose. Restore a
supported profile, restart the init service, then start the daemon. Avoid
changing profiles while it runs, because the saved profile is restored at the
end.

### `Permission denied` when started manually

Run the service instead:

```sh
sudo systemctl restart platform-profile-daemon.service
```

### Bus name already owned

Another daemon (for example `power-profiles-daemon`) owns the name:

```sh
busctl --system status org.freedesktop.UPower.PowerProfiles
```

Stop or disable the conflicting service.

### Desktop widget cannot switch profiles

Reinstall the package or policy files, restart the service, then read the log:

```sh
journalctl -u platform-profile-daemon.service --since "10 min ago"
```

A message such as `not authorized to switch power profile` comes from Polkit:
the session is inactive or remote. At most eight changes can wait for Polkit
at once, and a new request from the same client replaces its earlier pending
one, which then fails with `superseded by a newer profile change`.

### The daemon restarted by itself

Check the journal for `Watchdog timeout` (the daemon hung) or
`platform_profile watch lost` (it could not read the profile three times in
a row). systemd restarts it either way.

### The `custom` profile

If the firmware reports `custom` while running, the desktop keeps showing the
last valid profile and nothing is written. Select a supported profile to
synchronize the kernel again. The daemon never picks `balanced` on its own.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

See [LICENSE](LICENSE).
