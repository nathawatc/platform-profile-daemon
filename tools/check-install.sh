#!/usr/bin/env bash
set -euo pipefail

# Run after: zig build install --prefix /absolute/staging/path
prefix=${1:?usage: check-install.sh STAGED_PREFIX}
for binary in platform-profile-daemon platform-profile-daemon-init; do
    [[ $(stat -c %a "$prefix/lib/$binary") == 755 ]]
done
for file in \
    lib/systemd/system/platform-profile-daemon.service \
    lib/systemd/system/platform-profile-daemon-init.service \
    share/dbus-1/system-services/org.freedesktop.UPower.PowerProfiles.service \
    share/dbus-1/system.d/org.freedesktop.UPower.PowerProfiles.conf \
    share/polkit-1/actions/org.freedesktop.UPower.PowerProfiles.policy; do
    [[ $(stat -c %a "$prefix/$file") == 644 ]]
done

daemon=$prefix/lib/systemd/system/platform-profile-daemon.service
init=$prefix/lib/systemd/system/platform-profile-daemon-init.service
grep -qx 'Requires=platform-profile-daemon-init.service' "$daemon"
grep -qx 'After=platform-profile-daemon-init.service' "$daemon"
grep -qx 'Type=oneshot' "$init"
grep -qx 'RemainAfterExit=yes' "$init"
[[ $(grep '^ReadWritePaths=' "$daemon") == 'ReadWritePaths=/sys/firmware/acpi/platform_profile' ]]
[[ $(grep '^ReadWritePaths=' "$init") == 'ReadWritePaths=/sys/devices/system/cpu/cpufreq /sys/firmware/acpi/platform_profile' ]]
for unit in "$daemon" "$init"; do
    for setting in 'NoNewPrivileges=yes' 'CapabilityBoundingSet=' 'AmbientCapabilities=' \
        'ProtectSystem=strict' 'ReadOnlyPaths=/sys' 'SystemCallFilter=@system-service'; do
        grep -qx "$setting" "$unit"
    done
done
if grep -q '^Alias=power-profiles-daemon.service' "$daemon"; then
    ! grep -q '^Conflicts=.*power-profiles-daemon.service' "$daemon"
fi
if strings "$prefix/lib/platform-profile-daemon" | grep -q 'energy_performance_preference'; then
    echo 'Bootstrap code leaked into daemon' >&2
    exit 1
fi
echo 'Install permissions, dependencies, sysfs permissions, and binary separation passed.'
