#!/bin/bash
# Static guard against a set -e foot-gun class.
#
# checkup.sh runs under `set -e`. `grep -c` (and plain `grep`) EXIT 1 when there
# are zero matches — so `VAR=$(grep -c …)` aborts the whole script the moment a
# pattern legitimately matches nothing. This is not hypothetical: it shipped on
# main and aborted a full run mid-way on the first real repo whose type-aware
# lint produced output with zero project-service parse errors (the count was 0,
# grep -c exited 1, set -e killed checkup before most checks ran).
#
# The fix is always `… || true` (then `${VAR:-0}`). This test fails if any
# unguarded `grep -c` command substitution creeps back into the scanned scripts.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "no unguarded 'grep -c' command substitutions (set -e abort risk)"
# A `VAR=$(grep -c …)` is safe only if it ends with a `|| true` / `|| echo`
# fallback on the same line. Flag any that don't.
OFFENDERS=$(grep -rnE '=\$\(grep -c' "$CHECKUP_HOME"/bin/*.sh "$CHECKUP_HOME"/lib/*.sh "$CHECKUP_HOME"/docker/*.sh 2>/dev/null \
    | grep -vE '\|\| (true|echo)' || true)

if [ -z "$OFFENDERS" ]; then
    ok "every 'grep -c' substitution is guarded with || true / || echo"
else
    notok "unguarded 'grep -c' substitution(s) — add '|| true' (aborts under set -e on zero matches):"
    printf '%s\n' "$OFFENDERS" | sed 's/^/      /'
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
