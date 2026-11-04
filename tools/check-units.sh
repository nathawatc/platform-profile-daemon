#!/usr/bin/env bash
set -euo pipefail

# Scores the shipped units with `systemd-analyze security --offline` (no running
# systemd needed) and fails if either exposure level rises above the limit.
# Current scores are 0.9; the limit leaves room for one small regression.
# Never "fix" the score with ProtectKernelTunables, PrivateUsers or User=: each
# breaks the sysfs write the services exist for.
root=$(cd "$(dirname "$0")/.." && pwd)
limit=${UNIT_EXPOSURE_LIMIT:-1.2}

if ! command -v systemd-analyze > /dev/null 2>&1; then
	echo 'SKIP: systemd-analyze not found'
	exit 0
fi

for unit in platform-profile-daemon platform-profile-daemon-init; do
	if ! out=$(systemd-analyze security --offline=true --no-pager "$root/data/$unit.service" 2>&1); then
		if grep -qi 'offline' <<< "$out"; then
			echo 'SKIP: this systemd-analyze has no --offline mode'
			exit 0
		fi
		echo "$out" >&2
		exit 1
	fi
	score=$(sed -n 's/.*Overall exposure level for [^:]*: \([0-9.]*\).*/\1/p' <<< "$out")
	[[ -n $score ]] || {
		echo "could not read the exposure level of $unit" >&2
		exit 1
	}
	echo "$unit: exposure $score (limit $limit)"
	if ! awk -v s="$score" -v l="$limit" 'BEGIN { exit !(s <= l) }'; then
		grep '✗' <<< "$out" >&2 || true
		echo "$unit exceeds the exposure limit" >&2
		exit 1
	fi
done
echo 'Unit exposure limits passed.'
