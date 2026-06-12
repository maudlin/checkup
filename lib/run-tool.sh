#!/bin/bash
# lib/run-tool.sh
#
# Shared helpers for checkup.sh checks. Sourced — not executed directly.
#
# Contract (see README.md for the full design):
#   1. run_tool "<label>" <cmd> [args…]   captures stdout → reports/raw/<slug>.txt,
#                                          stderr → reports/raw/<slug>.stderr.txt (deleted if empty),
#                                          sets globals LAST_LABEL / LAST_SLUG / LAST_RAW /
#                                          LAST_STDERR / LAST_EXIT. ALWAYS returns 0 so that
#                                          `set -e` callers do not abort on expected non-zero
#                                          exits (e.g. lint with warnings, typecheck with errors).
#                                          Caller must consult $LAST_EXIT (127 = tool not on PATH).
#   2. write_parsed <slug> <status> <count> <summary> <top-json> <intent-json>
#                                          emits reports/parsed/<slug>.json conforming to
#                                          the shared schema.
#   3. is_valid_json <path>                guard for parsers that consume JSON-emitting tools.
#   4. slug <label>                        lowercase-kebab id used for filenames.
#
# Status vocabulary: pass | warn | fail | skip
# Severity vocabulary (top[].severity): critical | error | high | warning | medium | low | style | info
#
# Required env (set by checkup.sh before sourcing):
#   RAW_DIR     — usually reports/raw
#   PARSED_DIR  — usually reports/parsed

if [ -z "${RAW_DIR:-}" ] || [ -z "${PARSED_DIR:-}" ]; then
    echo "run-tool.sh: RAW_DIR and PARSED_DIR must be set before sourcing" >&2
    return 1 2>/dev/null || exit 1
fi

mkdir -p "$RAW_DIR" "$PARSED_DIR"

# slug "Some Label" → "some-label"
slug() {
    local s
    s=$(echo "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '-' \
        | sed -E 's/-+/-/g; s/^-//; s/-$//')
    printf '%s\n' "$s"
}

# is_valid_json <path> — returns 0 if file parses as JSON
is_valid_json() {
    [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1
}

# toolchain_absent — true when the Node-stack checks can't meaningfully run here,
# i.e. the most recent run_tool command wasn't on PATH (LAST_EXIT 127; run_tool
# also promotes `npm run <missing-script>` to 127) OR the target has no
# `package.json` (so it isn't a Node project at all). The latter matters because
# with npm installed but no package.json, `npm run …` exits non-127 — without
# this the Node sections would false-`fail` on a non-Node repo scanned from a
# host that happens to have node. Stack-specific sections (typecheck, test,
# build, lint, coverage, …) gate on this for an honest `skip` rather than a
# misread (empty output counted as "zero findings → pass", or a spurious fail).
# Caller's cwd is the scan target ($TARGET), so the package.json probe is correct.
toolchain_absent() {
    [ "${LAST_EXIT:-0}" = "127" ] || [ ! -f package.json ]
}

# is_fresh <path> <marker> — true if <path> is valid JSON AND newer than
# <marker> (a file touched immediately before the tool ran). Guards artifact
# readers (coverage, duplication) against trusting a stale report left in the
# source tree by a prior build when the current run produced nothing — e.g. the
# tool is absent, or present-but-failed. Without it those checks parse the
# pre-existing file and emit a confident false `pass`. Relies on sub-second
# mtime (ext4 et al.); the tool runs after the marker so its output sorts newer.
is_fresh() {
    [ -f "$1" ] && [ "$1" -nt "$2" ] && is_valid_json "$1"
}

# run_tool "<label>" <cmd> [args…]
#
# Captures stdout to $RAW_DIR/<slug>.txt and stderr to $RAW_DIR/<slug>.stderr.txt
# (deleted if empty). Sets the LAST_* globals so the calling parser can locate the
# raw output without re-deriving paths. NEVER aborts — caller must check $LAST_EXIT.
run_tool() {
    local label="$1"; shift
    local s
    s=$(slug "$label")

    LAST_LABEL="$label"
    LAST_SLUG="$s"
    LAST_RAW="$RAW_DIR/$s.txt"
    LAST_STDERR="$RAW_DIR/$s.stderr.txt"
    : > "$LAST_RAW"
    : > "$LAST_STDERR"

    if ! command -v "$1" >/dev/null 2>&1; then
        echo "⏭️  SKIP $label — '$1' not on PATH"
        LAST_EXIT=127
        return 0
    fi

    # Capture exit code via the `&& / ||` idiom so `set -e` in the caller
    # does not abort when the tool exits non-zero (which is expected for
    # lint-with-warnings, typecheck-with-errors, etc).
    "$@" > "$LAST_RAW" 2> "$LAST_STDERR" && LAST_EXIT=0 || LAST_EXIT=$?

    # `npm run <missing-script>` exits non-zero with a "Missing script"
    # diagnostic on stderr. Without this fix the section's parser sees an
    # empty $LAST_RAW and either passes (zero findings!) or misclassifies
    # the lack of output as a real failure — both wrong. Promoting to 127
    # routes the call through the section's existing graceful-degrade path
    # ("tool not installed" — close enough; the underlying issue is "this
    # check isn't wired up in your package.json yet").
    if [ "$LAST_EXIT" != "0" ] && [ -s "$LAST_STDERR" ] \
        && grep -q "npm ERR! Missing script" "$LAST_STDERR" 2>/dev/null; then
        LAST_EXIT=127
    fi

    [ -s "$LAST_STDERR" ] || rm -f "$LAST_STDERR"
    return 0
}

# write_parsed <slug> <status> <count> <summary> [top-json-array] [intent-json-object]
#
# Emits $PARSED_DIR/<slug>.json. top defaults to [], intent defaults to {}.
# Caller is responsible for the intent contents — typically a heredoc near the check definition.
write_parsed() {
    local slug="$1"
    local status="$2"
    local count="${3:-0}"
    local summary="$4"
    local top="${5:-[]}"
    local intent="${6:-{\}}"

    case "$status" in
        pass|warn|fail|skip) ;;
        *)
            echo "write_parsed: invalid status '$status' for $slug — must be pass|warn|fail|skip" >&2
            status="fail"
            ;;
    esac

    jq -n \
        --arg slug "$slug" \
        --arg status "$status" \
        --argjson count "$count" \
        --arg summary "$summary" \
        --argjson top "$top" \
        --argjson intent "$intent" \
        '{slug:$slug, status:$status, count:$count, summary:$summary, top:$top, intent:$intent}' \
        > "$PARSED_DIR/$slug.json"
}

# write_skipped <slug> <reason> [intent-json]
#
# Convenience for the "tool not installed / opt-in not enabled / prerequisite genuinely
# absent" case — we deliberately chose not to run the check. Always writes a parsed JSON
# so the report can show "what was supposed to run vs. what did", and carries the intent
# so the report still explains why the check matters.
#
# CONTRACT: use skipped ONLY when we never ran the tool. If the tool ran but produced
# unparseable output, use write_failed — otherwise the status downgrade silently hides
# a real failure (caught in adversarial review pre-PR).
write_skipped() {
    local slug="$1"
    local reason="$2"
    local intent="${3:-{\}}"
    write_parsed "$slug" "skip" 0 "$reason" '[]' "$intent"
}

# write_failed <slug> <reason> [intent-json]
#
# For the "tool ran but we can't interpret its output" case — missing/malformed report
# file, parse error, non-zero exit without diagnostic. Distinguishes the "we tried and
# got nothing usable" case from the deliberate-skip case. We can't claim "pass" because
# we have no evidence; "fail" with the reason surfaced is the honest status.
write_failed() {
    local slug="$1"
    local reason="$2"
    local intent="${3:-{\}}"
    write_parsed "$slug" "fail" 0 "$reason" '[]' "$intent"
}
