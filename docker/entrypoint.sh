#!/bin/bash
# checkup container entrypoint.
#
# Usage:
#   docker run --rm -v "$PWD:/src:ro" -v "$PWD/checkup-out:/out" checkup [TARGET]
#
# TARGET defaults to /src (the conventional read-only mount). The report and all
# machine-readable output land in /out (mount it to retrieve them). The source
# can be mounted read-only — checkup writes nothing into it.
set -e

TARGET="${1:-${CHECKUP_TARGET:-/src}}"
export CHECKUP_TARGET="$TARGET"
export CHECKUP_OUT_DIR="${CHECKUP_OUT_DIR:-/out}"

if [ ! -d "$TARGET" ]; then
    echo "checkup: target '$TARGET' is not a directory — mount your repo at /src" >&2
    echo "  e.g. docker run --rm -v \"\$PWD:/src:ro\" -v \"\$PWD/checkup-out:/out\" checkup" >&2
    exit 2
fi

# Mounted repos trip git's dubious-ownership guard (container user ≠ host
# owner). Trust the mount — it's read-only anyway.
git config --global --add safe.directory '*' 2>/dev/null || true

mkdir -p "$CHECKUP_OUT_DIR"

if [ ! -e "$TARGET/.git" ]; then
    echo "checkup: note — '$TARGET' has no .git; the git-forensics checks" >&2
    echo "        (churn, coupling, bug-fix density, branch hygiene) are limited." >&2
    echo "        Mount a full clone (not a shallow/exported tree) for those." >&2
fi

exec /opt/checkup/bin/checkup.sh
