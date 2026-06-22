#!/usr/bin/env bash
# scc-inventory.sh — make the scc-based engines honour the first-party inventory
# (plan 0002 Phase 1, #109; subsumes #18).
#
# The problem: codebase-stats, detection-dominance and tech-viability call scc
# directly with a hardcoded `--exclude-dir`, honouring neither the inventory (#75)
# nor CHECKUP_EXCLUDE — so the report self-contradicts ("N first-party assessed"
# next to "40,822 files / 14M lines"), and vendored/generated bulk skews identity
# (#78 Repro B) with no lever to fix it.
#
# The fix (spike-proven): scc has no file-list input and a dir/regex exclude model
# that can't express scattered generated/vendored files, so we let scc walk ONCE
# (`--by-file --format json`) and FILTER + RE-AGGREGATE its output against the
# inventory keep-set. One scc run feeds every consumer:
#   - the per-language breakdown (detection, codebase-stats, tech-viability) via
#     lib/scc-aggregate.jq;
#   - the per-file complexity ranking (the scc complexity arm), filtered to the
#     same keep-set, with a total-order sort for determinism (#96).
#
# Sourced — needs CHECKUP_HOME (to locate lib/scc-aggregate.jq) and jq on PATH.
# The keep-set (a JSON array of TARGET-relative first-party paths, ALL extensions
# — scc counts JSON/Markdown/config too, not just SOURCE_EXT_RE) is the caller's
# to supply; on a non-git / inventory-absent target the caller passes an empty
# keep-set and these helpers degrade to "[]", which routes to the existing skip.
#
# The pure transform is lib/scc-aggregate.jq (env-independent, unit-tested in
# test/scc-inventory.test.sh). These wrappers stay thin on purpose.

# ensure_scc_byfile <scc_bin>
#   Run scc --by-file ONCE over the scan roots, caching to $RAW_DIR/scc-byfile.json
#   so every scc-based engine shares a single walk (then filters to the keep-set).
#   Idempotent (guarded by SCC_BYFILE_DONE). Sets SCC_BYFILE (path) and
#   SCC_BYFILE_OK (true|false). Never aborts under set -e — callers branch on
#   SCC_BYFILE_OK and route an unusable result to their existing skip/fail path.
#   The --exclude-dir is kept only as a cheap pre-filter (those dirs are excluded
#   by the keep-set anyway); the keep-set is the real authority. scc respects
#   .gitignore itself, and --by-file streams per-file counts (memory-safe — unlike
#   lizard duplication, #105), so this is safe on very large trees.
ensure_scc_byfile() {
    local scc="$1"
    [ "${SCC_BYFILE_DONE:-}" = true ] && return 0
    SCC_BYFILE_DONE=true
    SCC_BYFILE="$RAW_DIR/scc-byfile.json"
    SCC_BYFILE_OK=false
    [ -n "$scc" ] || return 0
    "$scc" --by-file --format json --no-cocomo \
        --exclude-dir=node_modules,.svelte-kit,coverage,.prisma,build,dist \
        "${SCAN_ROOTS[@]}" > "$SCC_BYFILE" 2>/dev/null || true
    if is_valid_json "$SCC_BYFILE" && jq -e 'type=="array"' "$SCC_BYFILE" >/dev/null 2>&1; then
        SCC_BYFILE_OK=true
    fi
    return 0
}

# scc_breakdown <keepfile>
#   stdin:  scc --by-file --format json
#   stdout: [ {Name, Code, Count, Complexity, Lines} ]  (Code desc, Name asc),
#           keeping only files whose Location is in <keepfile> (a JSON array).
# <keepfile> is read via --slurpfile (no argv cap), so a 40k-path set is fine.
scc_breakdown() {
    local keepfile="$1"
    jq --slurpfile keep "$keepfile" -f "$CHECKUP_HOME/lib/scc-aggregate.jq"
}

# scc_breakdown_total <breakdown-json>  → "FILES CODE COMPLEXITY" (space-separated)
# Reconstructs the codebase-stats `Total` row from the breakdown — so the section
# need not parse scc's tabular output separately.
scc_breakdown_total() {
    printf '%s' "$1" | jq -r '"\((map(.Count)|add) // 0) \((map(.Code)|add) // 0) \((map(.Complexity)|add) // 0)"'
}

# scc_breakdown_toplangs <breakdown-json> [n]  → "Name Code, Name Code, …"
# The breakdown is already Code-desc, so this is just a slice — deterministic.
scc_breakdown_toplangs() {
    local n="${2:-3}"
    printf '%s' "$1" | jq -r --argjson n "$n" '
        .[0:$n] | map("\(.Name) \(.Code)") | join(", ")'
}

# scc_perfile_findings <keepfile>
#   stdin:  scc --by-file --format json
#   stdout: complexity findings array (file/line/ccn/lines/code/severity/message),
#           filtered to the keep-set, ranked by complexity with a TOTAL order
#           (-ccn, then file) so the ranking + the Tornhill CSV are byte-identical
#           run-to-run (#96 — scc's per-file walk order is nondeterministic).
scc_perfile_findings() {
    local keepfile="$1"
    jq --slurpfile keep "$keepfile" '
        ( ($keep[0] // []) | map({ key: sub("^\\./"; ""), value: true }) | from_entries ) as $k
        | [ .[].Files[]?
            | { loc: (.Location | sub("^\\./"; "")), ccn: (.Complexity // 0), lines: .Lines }
            | select( $k[.loc] // false )
            | select( .ccn > 0 )
            | { file: .loc, line: 1, ccn: .ccn, lines: .lines,
                code: ("complexity-" + (.ccn | tostring)),
                severity: (if .ccn >= 100 then "high" elif .ccn >= 50 then "warning" elif .ccn >= 25 then "low" else "info" end),
                message: ((.loc | sub(".*/"; "")) + " — scc complexity " + (.ccn | tostring) + " (" + (.lines | tostring) + " lines)") }
          ]
        | sort_by( -.ccn, .file )'
}
