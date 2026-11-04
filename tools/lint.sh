#!/usr/bin/env bash
set -euo pipefail

# Every static check in one place, run locally and by the CI lint job.
# Needs: zig, shellcheck, shfmt, ruff and rumdl on PATH.
cd "$(dirname "$0")/.."

for tool in zig shellcheck shfmt ruff rumdl; do
	command -v "$tool" > /dev/null 2>&1 || {
		echo "lint: $tool not found" >&2
		exit 1
	}
done

zig fmt --check src build.zig build.zig.zon
shellcheck tools/*.sh
shfmt -d -i 0 -sr -ci -bn tools/*.sh
ruff check tools
ruff format --check tools
rumdl check .
echo 'Lint passed.'
