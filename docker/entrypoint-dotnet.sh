#!/bin/bash
# checkup-dotnet container entrypoint.
#
# Usage:
#   docker run --rm -v "$PWD:/src:ro" -v "$PWD/checkup-out:/out" checkup-dotnet [TARGET]
#
# Identical conventions to checkup-core (read-only /src, output to /out) but runs
# the .NET / legacy-ASP overlay (core checks + asp-classic + devskim + dotnet-vuln).
set -e

TARGET="${1:-${CHECKUP_TARGET:-/src}}"
export CHECKUP_TARGET="$TARGET"
export CHECKUP_OUT_DIR="${CHECKUP_OUT_DIR:-/out}"

if [ ! -d "$TARGET" ]; then
    echo "checkup-dotnet: target '$TARGET' is not a directory — mount your repo at /src" >&2
    exit 2
fi

git config --global --add safe.directory '*' 2>/dev/null || true
mkdir -p "$CHECKUP_OUT_DIR"

if [ ! -e "$TARGET/.git" ]; then
    echo "checkup-dotnet: note — '$TARGET' has no .git; git-forensics checks are skipped." >&2
fi

exec /opt/checkup/bin/checkup-dotnet.sh
