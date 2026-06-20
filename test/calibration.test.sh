#!/bin/bash
# Tests for lib/calibrate.sh (plan 0001 §B) — calibration heuristics.
#
# Security-sensitive: the public-by-design classifier DOWNGRADES a secret finding,
# so it must be conservative — only on strong positive evidence (a public var-name
# pattern in the source line), never on a bare secret, and a no-op when the
# context is empty. Drives the SHARED is_public_by_design matcher directly, so the
# engine (bin/checkup.sh) and this test verify ONE definition (no drift).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/calibrate.sh
source "$CHECKUP_HOME/lib/calibrate.sh"

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

pbd()    { if is_public_by_design "$1"; then echo true; else echo false; fi; }
assert() { # <name> <expected> <source-line>
    local got; got=$(pbd "$3")
    [ "$got" = "$2" ] && ok "$1" || notok "$1 (expected $2, got $got)"
}

echo "public-by-design: client-shipped web keys → downgraded (hygiene)"
assert "VITE_ Firebase web key"       true  'VITE_FIREBASE_API_KEY=<redacted>'
assert "NEXT_PUBLIC_ prefix"          true  'NEXT_PUBLIC_KEY=abc123'
assert "REACT_APP_ prefix"           true  'REACT_APP_TOKEN: "xyz"'
assert "EXPO_PUBLIC_ prefix"          true  'EXPO_PUBLIC_X=1'
assert "GATSBY_ prefix"               true  'GATSBY_API=foo'
assert "PUBLIC_ (SvelteKit) prefix"   true  'PUBLIC_ANALYTICS_ID=g-123'
assert "bare FIREBASE_API_KEY"        true  'FIREBASE_API_KEY=<redacted>'
assert "case-insensitive (lower)"     true  'vite_firebase_api_key=<redacted>'

echo ""
echo "real secrets: NEVER downgraded (must stay full severity)"
assert "AWS key, no public prefix"    false 'const key = <redacted>'
assert "FIREBASE private key (not API key)" false 'FIREBASE_PRIVATE_KEY=<redacted>'
assert "empty context (heavy redaction)"    false ''
assert "substring 'republic' not a prefix"  false 'republican_secret=zzz'
assert "PUBLICITY (not PUBLIC_)"      false 'PUBLICITY_TOKEN=zzz'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
