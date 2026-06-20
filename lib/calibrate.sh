#!/bin/bash
# lib/calibrate.sh
#
# Sourced — not executed. Calibration knowledge (plan 0001 §B): the context a fair
# reader applies to a scanner's raw output so the report is fair, not just honest.
# A finding is never suppressed; its severity/framing is recalibrated with a
# documented heuristic, and the source-of-truth for each heuristic lives HERE so
# the engine (bin/checkup.sh) and its tests share ONE definition (no drift).

# Public-by-design credential patterns for the secret scan. A client-shipped web
# key is HYGIENE, not a breach: it is exposed in the client bundle by
# construction, so secrecy was never the control. Two signals:
#   - build-tool PUBLIC prefixes — frameworks that deliberately inline these into
#     the browser bundle (Vite, Next, CRA, Expo, Gatsby, Vue/Nuxt, SvelteKit
#     PUBLIC_);
#   - a Firebase web API key (FIREBASE…API_KEY) — documented by Google as safe to
#     expose; access is enforced by Firebase rules, not key secrecy.
# An ERE (no inline flags) so it works with `grep -iE` on GNU and BSD; case-
# insensitivity is applied by the caller's -i flag, keeping one pattern string.
CHECKUP_PBD_RE='(^|[^A-Za-z0-9_])(VITE_|NEXT_PUBLIC_|REACT_APP_|EXPO_PUBLIC_|PUBLIC_|GATSBY_|VUE_APP_|NUXT_PUBLIC_)[A-Za-z0-9_]*|FIREBASE[A-Za-z0-9_]*API_?KEY'

# is_public_by_design <source-line> — exit 0 if the source context names a
# client-shipped / public-by-design key. Classifies by the VAR NAME in the source
# line, because gitleaks' --redact zeroes the .Match field (the secret value never
# reaches our artifacts; the var name only survives in the file). Conservative:
# matches a name pattern, so a real secret without one is never downgraded; an
# empty/absent context (heavier redaction, unreadable file) is not a match.
is_public_by_design() {
    [ -n "${1:-}" ] && printf '%s' "$1" | grep -qiE "$CHECKUP_PBD_RE"
}
