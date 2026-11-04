#!/usr/bin/env bash
set -euo pipefail

# Run after: zig build install --prefix /absolute/staging/path
# The shipped ReleaseSmall binaries are tiny on purpose; fail if either grows
# past its budget (about 20% headroom over the current size).
prefix=${1:?usage: check-size.sh STAGED_PREFIX}

check() {
	local binary=$1 limit=$2 size
	size=$(stat -c %s "$prefix/lib/$binary")
	echo "$binary: $size bytes (budget $limit)"
	if ((size > limit)); then
		echo "$binary exceeds its size budget" >&2
		exit 1
	fi
}

check platform-profile-daemon 28672
check platform-profile-daemon-init 12288
echo 'Binary size budgets passed.'
