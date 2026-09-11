#!/usr/bin/env bash
set -euo pipefail

# All mounts and writes occur inside a fresh user/mount namespace and temp tree.
if [[ ${1:-} != --inside ]]; then
	binary=$(realpath "${1:-zig-out/lib/platform-profile-daemon-init}")
	exec unshare --user --map-root-user --mount bash "$0" --inside "$binary"
fi
binary=${2:?missing init binary}
tree=$(mktemp -d /tmp/platform-profile-init-smoke.XXXXXXXX)
failure_path=
trap 'if [[ -n "$failure_path" ]]; then umount "$failure_path"; fi; umount /sys/devices/system/cpu/cpufreq; umount /sys/firmware/acpi; rm -r -- "$tree"' EXIT
mkdir -p "$tree/acpi" "$tree/cpu/policy0" "$tree/cpu/policy1"
mount --bind "$tree/acpi" /sys/firmware/acpi
mount --bind "$tree/cpu" /sys/devices/system/cpu/cpufreq
profile=$tree/acpi/platform_profile
for initial in low-power balanced performance; do
	printf '%s' "$initial" > "$profile"
	printf 'default\n' > "$tree/cpu/policy0/energy_performance_preference"
	printf 'default\n' > "$tree/cpu/policy1/energy_performance_preference"
	"$binary"
	[[ $(cat "$profile") == "$initial" ]]
	[[ $(cat "$tree/cpu/policy0/energy_performance_preference") == dynamic ]]
	[[ $(cat "$tree/cpu/policy1/energy_performance_preference") == dynamic ]]
done

printf 'custom\n' > "$profile"
if "$binary" 2> "$tree/error"; then exit 1; fi
grep -q '/sys/firmware/acpi/platform_profile: UnknownKernelProfile' "$tree/error"
[[ $(cat "$profile") == custom ]]

# Fail each policy in turn so partial failure is covered regardless of order.
partial_seen=false
for failed in policy0 policy1; do
	printf 'low-power\n' > "$profile"
	for policy in policy0 policy1; do
		printf 'default\n' > "$tree/cpu/$policy/energy_performance_preference"
	done
	failure_path=/sys/devices/system/cpu/cpufreq/$failed/energy_performance_preference
	mount --bind /dev/full "$failure_path"
	if "$binary" 2> "$tree/error"; then exit 1; fi
	grep -q "$failed/energy_performance_preference: WriteFailed (errno 28: NOSPC)" "$tree/error"
	for policy in policy0 policy1; do
		[[ $policy == "$failed" ]] && continue
		value=$(cat "$tree/cpu/$policy/energy_performance_preference")
		if [[ $value == dynamic ]]; then
			partial_seen=true
		else
			[[ $value == default ]]
		fi
	done
	[[ $(cat "$profile") == low-power ]]
	umount "$failure_path"
	failure_path=
done
[[ $partial_seen == true ]]
echo 'Init executable smoke passed: supported profiles, custom rejection, partial write failure, errno diagnostics.'
