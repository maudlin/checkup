#!/usr/bin/env bash
# Source inventory (#75) — the ONE honest answer to "what source should checkup
# assess?", so the tool never mistakes "we didn't look" for "nothing's there".
#
# Instead of guessing roots from a hard-coded `src server` convention (which
# silently scoped out code kept under scripts/, prisma/, packages/, …), the scope
# is enumerated from the project's OWN notion of source — the VCS — and is
# `.gitignore`-aware for free, so generated/vendored junk (a `.vercel/` build
# output, a committed bundle) doesn't pollute the localiser. Three tiers, honest
# fallback:
#   1. git repo   → `git ls-files` (tracked files; respects .gitignore inherently)
#   2. non-git+fd → `fd` (respects .gitignore/.ignore) — used only if present
#   3. non-git    → `find` with the builtin excludes (a legacy tree has no
#                   .gitignore to honour anyway)
#
# The result is a single NUL-delimited file list ($RAW_DIR/source-files.lst) plus
# a count and a scope label. Scanners that don't honour .gitignore (lizard) are
# fed this list directly; scanners that traverse themselves (eslint, scc) keep
# their own invocation and their findings are filtered back to this list, so the
# inventory is the single authority for "what counts".
#
# Sourced (not executed) — needs GIT_OK / TARGET / SCAN_ROOTS / RAW_DIR from the
# orchestrator. The pure filter (_filter_inventory) takes its input on stdin so
# it is unit-testable with no git/fd/find present (mirrors lib/detect-stacks.jq's
# "one shared transform, env-independent test" pattern).

# Extensions checkup measures per-function / per-file (lizard-parseable plus the
# JS/TS module variants). Anchored at end-of-path; used by the pure filter and by
# inventory_paths. Keep in sync with the probe sets in bin/checkup.sh.
SOURCE_EXT_RE='\.(ts|tsx|js|jsx|mjs|cjs|svelte|vue|py|cs|java|kt|kts|go|rb|php|rs|c|cc|cpp|cxx|h|hpp|m|mm|swift|scala|lua)$'

# Sub-slices, so each scanner gets exactly the files it can parse:
INV_JSTS_RE='\.(ts|tsx|js|jsx|mjs|cjs|svelte|vue)$'                                           # ESLint / Node engines
INV_NONJS_RE='\.(py|cs|java|kt|kts|go|rb|php|rs|c|cc|cpp|cxx|h|hpp|m|mm|swift|scala|lua)$'      # lizard's non-JS slice (#68)
INV_LIZARD_RE='\.(ts|tsx|js|jsx|py|cs|java|kt|kts|go|rb|php|rs|c|cc|cpp|cxx|h|hpp|m|mm|swift|scala|lua)$'  # everything lizard tokenises

# Should this path be excluded as tracked-but-noisy? `.gitignore` already drops
# generated/ignored output; this catches the COMMITTED noise it doesn't —
# vendored trees, minified bundles, migrations, snapshots — that would otherwise
# dominate the complexity/duplication signal. Mirrors the prior LIZARD_EXCLUDES
# globs; CHECKUP_EXCLUDE adds more (space-separated), same as before.
_inventory_excluded() {
    local p="$1" g
    # Directory excludes: match against "/$p" so a LEADING segment (top-level
    # node_modules/, dist/) is caught the same as a nested one (*/node_modules/*).
    case "/$p" in
        */node_modules/*|*/dist/*|*/build/*|*/.svelte-kit/*|\
        */vendor/*|*/vendored/*|*/third_party/*|\
        */migrations/*|*/__snapshots__/*|*/snapshots/*) return 0 ;;
    esac
    # File-suffix excludes (committed minified/generated/snapshot files).
    case "$p" in *.min.js|*.min.css|*.bundle.js|*.snap) return 0 ;; esac
    if [ -n "${CHECKUP_EXCLUDE:-}" ]; then
        # Split CHECKUP_EXCLUDE into globs WITH pathname expansion disabled: the
        # caller's cwd is the scan target, so an unguarded `for g in $CHECKUP_EXCLUDE`
        # would glob a directory pattern like `vendor/js/*` against the filesystem
        # (expanding it to its literal children, which then never match a nested
        # path) — the reason directory excludes silently did nothing (#109/#18).
        # `set -f` stops that; the `case` pattern below is matched as a glob anyway.
        local g _had_noglob; case $- in *f*) _had_noglob=1 ;; *) _had_noglob=0 ;; esac
        set -f
        # shellcheck disable=SC2086  # intentional word-split into glob patterns
        for g in $CHECKUP_EXCLUDE; do
            # shellcheck disable=SC2254  # $g is an intentional glob pattern
            case "$p" in $g) [ "$_had_noglob" = 0 ] && set +f; return 0 ;; esac
        done
        [ "$_had_noglob" = 0 ] && set +f
    fi
    return 1
}

# Pure filter: NUL-delimited candidate paths on stdin → NUL-delimited source
# paths on stdout (source extension AND not excluded). No git/fd/find needed, so
# the test can inject a synthetic list. NUL throughout so paths with spaces or
# newlines survive.
_filter_inventory() {
    local p
    while IFS= read -r -d '' p; do
        p="${p#./}"   # normalise the find/fd "./" prefix → one TARGET-relative namespace
        [[ "$p" =~ $SOURCE_EXT_RE ]] || continue
        _inventory_excluded "$p" && continue
        printf '%s\0' "$p"
    done
}

# Resolve the scan roots. Default is the whole tree (".") — honest by default.
# CHECKUP_SRC_ROOTS NARROWS it (focus, or perf on a huge monorepo): space-
# separated, filtered to roots that actually exist; if none exist, fall back to
# the whole tree rather than scanning nothing.
resolve_scan_roots() {
    SCAN_ROOTS=()
    if [ -n "${CHECKUP_SRC_ROOTS:-}" ]; then
        local r
        # shellcheck disable=SC2206  # intentional word-split of the override list
        local requested=(${CHECKUP_SRC_ROOTS})
        for r in "${requested[@]}"; do [ -d "$r" ] && SCAN_ROOTS+=("$r"); done
    fi
    [ "${#SCAN_ROOTS[@]}" -eq 0 ] && SCAN_ROOTS=(".")
    return 0   # never let a false final test trip `set -e` in the caller
}

# Build the inventory. Writes $RAW_DIR/source-files.lst (NUL-delimited), sets
# SOURCE_FILE_COUNT, SOURCE_SCOPE, SOURCE_LST. Run AFTER resolve_scan_roots and
# with cwd == TARGET (so paths are TARGET-relative, sharing the namespace the
# file scanners + git-forensics use).
build_source_inventory() {
    local lst="$RAW_DIR/source-files.lst"
    mkdir -p "$RAW_DIR"
    if [ "${GIT_OK:-false}" = true ]; then
        SOURCE_SCOPE="git"
        git ls-files -z -- "${SCAN_ROOTS[@]}" 2>/dev/null | _filter_inventory > "$lst"
    elif command -v fd > /dev/null 2>&1; then
        SOURCE_SCOPE="fd"
        fd --type f --hidden --no-follow --print0 . "${SCAN_ROOTS[@]}" 2>/dev/null | _filter_inventory > "$lst"
    else
        SOURCE_SCOPE="find"
        find "${SCAN_ROOTS[@]}" \( -name node_modules -o -name .git \) -prune -o \
            -type f -print0 2>/dev/null | _filter_inventory > "$lst"
    fi
    [ -n "${CHECKUP_SRC_ROOTS:-}" ] && SOURCE_SCOPE="override:$SOURCE_SCOPE"
    SOURCE_LST="$lst"
    SOURCE_FILE_COUNT=$(tr -cd '\0' < "$lst" | wc -c | tr -d ' ')
}

# Like _filter_inventory, but WITHOUT the source-extension allow-list — only the
# provenance/convention/CHECKUP_EXCLUDE exclusion. This is the keep-set for the
# scc-based engines (stats/identity/tech-viability), which count ALL languages —
# first-party JSON/Markdown/config too, not just the SOURCE_EXT_RE slice that
# lizard/ESLint measure per-function. Same normalisation + exclusion as the source
# filter, so the two share one namespace and one notion of "excluded".
_filter_keep() {
    local p
    while IFS= read -r -d '' p; do
        p="${p#./}"
        _inventory_excluded "$p" && continue
        printf '%s\0' "$p"
    done
}

# Build the scc keep-set: VCS-tracked files (ALL extensions) minus the exclusions,
# as a JSON array at $RAW_DIR/scc-keep.json (sets SCC_KEEP_JSON). The scc-based
# engines filter their --by-file output against this (lib/scc-inventory.sh), so
# stats/identity reflect first-party code, not the whole tree (#109). Same tiers
# as build_source_inventory; run AFTER resolve_scan_roots, cwd == TARGET.
build_scc_keepset() {
    local lst="$RAW_DIR/scc-keep.lst"
    SCC_KEEP_JSON="$RAW_DIR/scc-keep.json"
    mkdir -p "$RAW_DIR"
    if [ "${GIT_OK:-false}" = true ]; then
        git ls-files -z -- "${SCAN_ROOTS[@]}" 2>/dev/null | _filter_keep > "$lst"
    elif command -v fd > /dev/null 2>&1; then
        fd --type f --hidden --no-follow --print0 . "${SCAN_ROOTS[@]}" 2>/dev/null | _filter_keep > "$lst"
    else
        find "${SCAN_ROOTS[@]}" \( -name node_modules -o -name .git \) -prune -o \
            -type f -print0 2>/dev/null | _filter_keep > "$lst"
    fi
    jq -Rs 'split("\u0000") | map(select(length > 0))' < "$lst" > "$SCC_KEEP_JSON" 2>/dev/null \
        || printf '[]' > "$SCC_KEEP_JSON"
    return 0
}

# Emit (NUL-delimited) the inventory paths whose extension matches $1 (an ERE
# alternation anchored by the caller, e.g. "$INV_NONJS_RE"). Empty $1 → all.
# Consume with: mapfile -d '' ARR < <(inventory_paths "$INV_NONJS_RE")
inventory_paths() {
    local re="${1:-}" p
    [ -f "${SOURCE_LST:-}" ] || return 0
    while IFS= read -r -d '' p; do
        [ -z "$re" ] || [[ "$p" =~ $re ]] || continue
        printf '%s\0' "$p"
    done < "$SOURCE_LST"
}

# The inventory as a JSON array of paths — for filtering a scanner's findings
# back to the tracked set (e.g. ESLint, which traverses on its own).
inventory_json() {
    inventory_paths "${1:-}" | jq -Rs 'split("\u0000") | map(select(length > 0))'
}

# The inventory grouped by top-level directory -> JSON object {area: count}, for
# the coverage signal (#75). Root-level files roll up under "<root>". NUL list is
# converted to newlines first (paths with embedded newlines are vanishingly rare
# and only affect this display grouping, never measurement).
inventory_by_area_json() {
    inventory_paths "" | tr '\0' '\n' | jq -R -s '
        split("\n") | map(select(length > 0))
        | group_by(if contains("/") then split("/")[0] else "<root>" end)
        | map({ key: (.[0] | if contains("/") then split("/")[0] else "<root>" end),
                value: length })
        | from_entries'
}

# Where the inventory got its exclusions from, for honest reporting. git/fd
# honour the repo's .gitignore; the find fallback only has checkup's builtin
# vendored/generated globs.
inventory_exclusion_source() {
    case "${SOURCE_SCOPE:-}" in
        *git)  echo ".gitignore" ;;
        *fd)   echo ".gitignore + .ignore" ;;
        *)     echo "builtin excludes (no VCS)" ;;
    esac
}

# Resolve an ESLint flat config at <dir> (default "."). Prints the first
# eslint.config.{js,mjs,cjs,ts}, or nothing + rc 1. This is the ONLY place
# `eslint .` from the root resolves a flat config (ESLint v9 does not search
# upward for the root invocation), so it gates the ESLint complexity slice (#79)
# — and #73 reuses it for the non-node-dominant case. Pure: a file test, no eslint
# needed, so it's unit-testable.
eslint_flat_config_root() {
    local dir="${1:-.}" c
    for c in eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts; do
        [ -f "$dir/$c" ] && { printf '%s' "$dir/$c"; return 0; }
    done
    return 1
}
