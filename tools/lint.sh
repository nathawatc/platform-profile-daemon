#!/usr/bin/env bash
set -euo pipefail

# Every static check in one place, run locally and by the CI lint job.
# Needs: zig, shellcheck, shfmt, ruff and rumdl on PATH.
cd "$(dirname "$0")/.."

missing=()
for tool in zig shellcheck shfmt ruff rumdl; do
	command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
	echo "lint: not found on PATH: ${missing[*]}" >&2
	exit 1
fi

# Every tracked file of each kind, except the vendored skills (not ours).
mapfile -t zig_files < <(git ls-files '*.zig' '*.zon')
mapfile -t shell_files < <(git ls-files '*.sh' ':!:.agents' ':!:.claude')

zig fmt --check "${zig_files[@]}"
shellcheck "${shell_files[@]}"
shfmt -d -i 0 -sr -ci -bn "${shell_files[@]}"
ruff check tools
ruff format --check tools
rumdl check .
echo 'Lint passed.'
