#!/bin/bash
# Honesty harness (plan 0001 §A) — the regression net for the #80/#85/#91 class.
#
# Those three bugs were all the same shape: a project-built check, run against a
# repo whose toolchain is PRESENT but cannot actually run (a manifest with no
# scripts, no lockfile, an uninstalled runner), read the tool's absence
# diagnostic as a finding and reported a false `fail`/`pass` instead of an honest
# `skip`. They recurred because the existing suite tests *mirrors* of section
# logic, not the sections themselves.
#
# This test runs the REAL bin/checkup.sh against a synthetic "manifest-present-
# but-toolchain-absent" fixture, with a fake `npm` on PATH emitting the genuine
# absence diagnostics (Missing script / ENOLOCK / empty `outdated`). It asserts
# the honesty invariant: every project-built check is `skip` — never a false
# pass/fail — with a reason. A regression of the class fails here.
#
# Hermetic: the fake npm means no real Node toolchain is needed; cross-stack
# scanners (scc/gitleaks/…) are absent in CI and simply skip (not asserted).
# Temp dirs live under $HOME because /tmp is noexec on some hosts and the fake
# npm must be executable.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK=$(mktemp -d "$HOME/.checkup-honesty.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

FIXTURE="$WORK/fixture"
OUT="$WORK/out"
FAKEBIN="$WORK/bin"
mkdir -p "$FIXTURE/src" "$OUT" "$FAKEBIN"

# Fixture: a Node manifest is PRESENT (so toolchain_absent's package.json probe
# is false — forcing the interesting LAST_EXIT-driven path), but there is no
# lockfile and no node_modules — the exact #80/#85/#91 condition.
cat > "$FIXTURE/package.json" <<'JSON'
{ "name": "honesty-fixture", "version": "1.0.0" }
JSON
echo 'export const x = 1;' > "$FIXTURE/src/a.ts"

# Fake npm emitting the REAL absence diagnostics, dispatched on subcommand:
#   - run / test / start / stop / restart → "Missing script" (npm lifecycle
#     aliases error the same way `npm run <missing>` does) (#80, #91)
#   - audit   → an ENOLOCK error object, valid JSON but no audit happened (#85)
#   - outdated → "{}" — empty, indistinguishable from "all current" without a
#     resolvable tree (#85)
cat > "$FAKEBIN/npm" <<'NPM'
#!/bin/bash
case "$1" in
  run|test|start|stop|restart) echo 'npm error Missing script: "'"${2:-$1}"'"' >&2; exit 1 ;;
  audit)      echo '{"error":{"code":"ENOLOCK","summary":"This command requires an existing lockfile."}}'; exit 1 ;;
  outdated)   echo '{}'; exit 0 ;;
  ci|install) echo 'npm error code ENOLOCK' >&2; exit 1 ;;
  *)          exit 0 ;;
esac
NPM
chmod +x "$FAKEBIN/npm"
# npx is sometimes invoked directly (type-aware-lint, mutation); make it absent-
# but-present so it degrades honestly rather than reaching the network.
cat > "$FAKEBIN/npx" <<'NPX'
#!/bin/bash
echo 'npm error could not determine executable to run' >&2; exit 1
NPX
chmod +x "$FAKEBIN/npx"

# Run the real engine. audit mode = never reach the network; the fake npm shadows
# any real one. Output goes outside the fixture.
PATH="$FAKEBIN:$PATH" CHECKUP_MODE=audit CHECKUP_TARGET="$FIXTURE" CHECKUP_OUT_DIR="$OUT" \
    bash "$CHECKUP_HOME/bin/checkup.sh" > "$OUT/run.log" 2>&1
RUN_EXIT=$?

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "honesty harness — real sections against a toolchain-absent fixture"
[ "$RUN_EXIT" = 0 ] && ok "checkup.sh ran (audit mode exits 0)" \
                    || notok "checkup.sh exited $RUN_EXIT (see run.log)"

# The checks that MUST skip when the Node toolchain can't run. A false pass or
# fail on any of these is the #80/#85/#91 bug class.
PROJECT_BUILT="typecheck unit-tests code-quality type-aware-lint build npm-audit \
               deps-freshness circular-deps duplication unused-code coverage mutation"

for slug in $PROJECT_BUILT; do
    f="$OUT/parsed/$slug.json"
    if [ ! -f "$f" ]; then
        notok "$slug — parsed record missing"
        continue
    fi
    status=$(jq -r '.status' "$f" 2>/dev/null)
    summary=$(jq -r '.summary // ""' "$f" 2>/dev/null)
    if [ "$status" = "skip" ] && [ -n "$summary" ]; then
        ok "$slug → skip (honest)"
    else
        notok "$slug → '$status' (expected skip) — honesty violation: $summary"
    fi
done

# Belt-and-braces: NO project-built check may carry a finding count > 0 here —
# there is nothing to find, only a toolchain that couldn't run.
for slug in $PROJECT_BUILT; do
    f="$OUT/parsed/$slug.json"; [ -f "$f" ] || continue
    cnt=$(jq -r '.count // 0' "$f" 2>/dev/null)
    [ "${cnt:-0}" -eq 0 ] || notok "$slug — count=$cnt on a toolchain-absent repo (phantom findings)"
done

# ── Coverage tripwire (plan 0001 §A) ──────────────────────────────────────────
# The behavioural assertions above check a HARDCODED list of slugs. That list can
# drift: a newly-added project-built check would silently escape the honesty net.
# This tripwire keeps them in sync — it asserts the set of profile-driven checks
# in bin/checkup.sh (the project-built node checks) is exactly the set we know
# about, so adding one without honesty coverage fails CI and forces a conscious
# decision (cover it behaviourally above, or allowlist it here with a reason).
echo ""
echo "coverage tripwire — every project-built (profiled) check is accounted for"

# Profiled checks that are NOT node-toolchain-absent honesty targets, with why:
#   SECURITY — semgrep; cross-stack, runs regardless of the Node toolchain and
#              guards on its own JSON validity, not toolchain_absent.
ALLOWLIST="SECURITY"

# The profiled checks we KNOW are covered by the behavioural assertions above
# (run_profiled NAME → a project-built slug the harness verifies skips).
EXPECTED_COVERED="AUDIT BUILD COVERAGE DEPS FORMAT LINT MUTATION OUTDATED TEST TYPEAWARE TYPECHECK UNUSED"

ACTUAL=$(grep -oE 'run_profiled [A-Z]+' "$CHECKUP_HOME/bin/checkup.sh" | awk '{print $2}' | sort -u)
# Drop the allowlisted ones.
for a in $ALLOWLIST; do ACTUAL=$(printf '%s\n' "$ACTUAL" | grep -vx "$a"); done
ACTUAL=$(printf '%s\n' "$ACTUAL" | grep -v '^$' | sort -u)
WANT=$(printf '%s\n' "$EXPECTED_COVERED" | tr ' ' '\n' | sort -u)

if [ "$ACTUAL" = "$WANT" ]; then
    ok "profiled check set matches the honesty-covered set (no unguarded checks)"
else
    notok "profiled check set drifted — cover the new check in the harness above, or allowlist it"
    echo "    unexpected (profiled, not covered): $(comm -23 <(printf '%s\n' "$ACTUAL") <(printf '%s\n' "$WANT") | tr '\n' ' ')"
    echo "    missing (expected, not found):      $(comm -13 <(printf '%s\n' "$ACTUAL") <(printf '%s\n' "$WANT") | tr '\n' ' ')"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
