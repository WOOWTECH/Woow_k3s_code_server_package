#!/usr/bin/env bash
# Preserve the upstream charts/<name> and shared/ layout without editing the mirror.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/charts"
cp -a "$root/chart" "$scratch/charts/code-server"
cp -a "$root/validation/shared" "$scratch/shared"
for test in "$scratch"/charts/code-server/tests/*.sh; do
    echo "Running $(basename "$test")"
    bash "$test"
done
