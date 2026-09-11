#!/usr/bin/env bash
set -euo pipefail

BUS_NAME="org.freedesktop.UPower.PowerProfiles"
OBJECT_PATH="/org/freedesktop/UPower/PowerProfiles"
INTERFACE="org.freedesktop.UPower.PowerProfiles"
PROP_IFACE="org.freedesktop.DBus.Properties"
PLATFORM_PROFILE_PATH="${PLATFORM_PROFILE_PATH:-/sys/firmware/acpi/platform_profile}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

run_ok() {
    echo "+ $*"
    "$@"
}

run_fail() {
    echo "+ (expect fail) $*"
    if "$@"; then
        die "command unexpectedly succeeded: $*"
    fi
}

map_to_kernel() {
    case "$1" in
        power-saver) echo "low-power" ;;
        balanced) echo "balanced" ;;
        performance) echo "performance" ;;
        *) die "unexpected dbus profile: $1" ;;
    esac
}

extract_active_profile() {
    busctl --system get-property "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE" ActiveProfile | awk '{print $2}' | tr -d '"'
}

assert_profile_state() {
    local expected_active="$1"
    local expected_kernel="$2"
    local current kernel_value

    current="$(extract_active_profile)"
    [[ "$current" == "$expected_active" ]] || die "ActiveProfile changed unexpectedly: expected=$expected_active got=$current"

    kernel_value="$(tr -d '\n' < "$PLATFORM_PROFILE_PATH")"
    [[ "$kernel_value" == "$expected_kernel" ]] || die "sysfs changed unexpectedly: expected=$expected_kernel got=$kernel_value"
}

restore_original() {
    if [[ -n "${ORIGINAL_PROFILE:-}" ]]; then
        echo "Restoring original profile: $ORIGINAL_PROFILE"
        busctl --system set-property "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE" ActiveProfile s "$ORIGINAL_PROFILE" || true
    fi
}

[[ $EUID -eq 0 ]] || die "run as root (busctl --system set-property requires privileges on many systems)"
command -v busctl >/dev/null 2>&1 || die "missing busctl"
[[ -e "$PLATFORM_PROFILE_PATH" ]] || die "sysfs path not found: $PLATFORM_PROFILE_PATH"
[[ -w "$PLATFORM_PROFILE_PATH" ]] || die "sysfs path is not writable: $PLATFORM_PROFILE_PATH"

trap restore_original EXIT

ORIGINAL_PROFILE="$(extract_active_profile || true)"
echo "Original ActiveProfile: ${ORIGINAL_PROFILE:-<unknown>}"

run_ok busctl --system get-property "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE" ActiveProfile
run_ok busctl --system get-property "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE" Profiles
run_ok busctl --system call "$BUS_NAME" "$OBJECT_PATH" "$PROP_IFACE" GetAll s "$INTERFACE"

INTROSPECTION="$(busctl --system introspect "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE")"
printf '%s\n' "$INTROSPECTION"

for member in PerformanceInhibited BatteryAware HoldProfile ReleaseProfile SetActionEnabled ProfileReleased; do
    if grep -Eq "^[[:space:]]*\.${member}[[:space:]]" <<< "$INTROSPECTION"; then
        die "unsupported D-Bus member is advertised: $member"
    fi
done

for member in ActiveProfile Profiles PerformanceDegraded Actions ActionsInfo ActiveProfileHolds Version; do
    grep -Eq "^[[:space:]]*\.${member}[[:space:]]" <<< "$INTROSPECTION" || \
        die "missing D-Bus member: $member"
done

for dbus_profile in power-saver balanced performance; do
    run_ok busctl --system set-property "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE" ActiveProfile s "$dbus_profile"
    current="$(extract_active_profile)"
    [[ "$current" == "$dbus_profile" ]] || die "ActiveProfile mismatch: expected=$dbus_profile got=$current"

    expected_kernel="$(map_to_kernel "$dbus_profile")"
    kernel_value="$(tr -d '\n' < "$PLATFORM_PROFILE_PATH")"
    [[ "$kernel_value" == "$expected_kernel" ]] || die "sysfs mismatch: expected=$expected_kernel got=$kernel_value"
done

INVALID_BASELINE_ACTIVE="$(extract_active_profile)"
INVALID_BASELINE_KERNEL="$(tr -d '\n' < "$PLATFORM_PROFILE_PATH")"

run_fail busctl --system set-property "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE" ActiveProfile s invalid-profile
assert_profile_state "$INVALID_BASELINE_ACTIVE" "$INVALID_BASELINE_KERNEL"
run_fail busctl --system set-property "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE" ActiveProfile b true
assert_profile_state "$INVALID_BASELINE_ACTIVE" "$INVALID_BASELINE_KERNEL"
run_fail busctl --system set-property "$BUS_NAME" "$OBJECT_PATH" org.freedesktop.UPower.NotPowerProfiles ActiveProfile s balanced
assert_profile_state "$INVALID_BASELINE_ACTIVE" "$INVALID_BASELINE_KERNEL"
run_fail busctl --system set-property "$BUS_NAME" "$OBJECT_PATH" "$INTERFACE" NotARealProperty s balanced
assert_profile_state "$INVALID_BASELINE_ACTIVE" "$INVALID_BASELINE_KERNEL"
run_fail busctl --system set-property "$BUS_NAME" /org/freedesktop/UPower/NotPowerProfiles "$INTERFACE" ActiveProfile s balanced
assert_profile_state "$INVALID_BASELINE_ACTIVE" "$INVALID_BASELINE_KERNEL"

echo "D-Bus smoke test passed."
