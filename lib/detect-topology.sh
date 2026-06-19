#!/bin/bash
# lib/detect-topology.sh
#
# Sourced — not executed. Pure, unit-testable helpers to classify a repo's
# package topology (#78): "the scan root is a hypothesis, not a fact."
#
# A low-quality / inherited codebase often roots a thin ORCHESTRATOR (a
# package.json whose scripts only `cd` into sub-dirs, with no lockfile of its own)
# over the real packages one level down. checkup, modelling the target as a single
# package at the scan root, then points its whole battery at glue and reports a
# pile of skips / false passes. This classifier tells four shapes apart:
#
#   single             — a normal single package at the root (today's happy path).
#   declared-workspace — npm/pnpm/yarn workspaces, nx, turbo or lerna. HEALTHY:
#                        the multi-package layout is declared and tool-managed.
#   undeclared-fan-out — ≥2 child packages, each with its OWN lockfile, under a
#                        thin orchestrator root (no lockfile, no `workspaces`, only
#                        glue scripts). A mild STRUCTURAL SMELL — and the case
#                        where the real work lives below the scan root.
#   orphan-root        — a root package.json with no real scripts, no lockfile and
#                        no child packages. Degenerate.
#
# The discriminator that matters is DECLARED vs UNDECLARED — a real workspace must
# never trip the smell alarm (don't cry wolf). The classifier is pure (takes
# pre-gathered signals); the filesystem gathering lives in the thin helpers below
# so the core logic can be driven by tests with no real tree.

# topology_script_is_glue "<script-body>" — exit 0 when an npm script body is mere
# orchestration glue (delegates into sub-packages / task runners) rather than
# doing real work itself. Conservative: anything not recognised as delegation
# counts as a real script. Used to decide whether a root has scripts of its own.
topology_script_is_glue() {
    local body="$1"
    [ -z "$body" ] && return 0   # empty / no-op → not a real script
    # Strip leading whitespace so a leading `cd`/runner is matched at the start.
    local b="${body#"${body%%[![:space:]]*}"}"
    case "$b" in
        cd\ *)                                            return 0 ;;  # cd into a sub-dir
        concurrently*|npm-run-all*|run-p|run-s|run-p\ *|run-s\ *) return 0 ;;  # multi-runners
        turbo|turbo\ *|nx\ *|lerna\ *)                    return 0 ;;  # monorepo task runners
        npm\ run\ *|npm\ --prefix*|npm\ -w\ *|npm\ --workspace*)  return 0 ;;  # npm delegation
        pnpm\ -r\ *|pnpm\ --filter*|pnpm\ -F\ *|pnpm\ run\ *)     return 0 ;;  # pnpm delegation
        yarn\ workspace*|yarn\ workspaces*)               return 0 ;;  # yarn workspaces
        *)                                                return 1 ;;  # real work
    esac
}

# topology_has_real_scripts "<package.json-path>" — exit 0 if the manifest defines
# at least one script that is NOT pure glue (per topology_script_is_glue). Missing
# file / no scripts / all-glue → exit 1 (no real scripts of its own).
topology_has_real_scripts() {
    local pkg="$1"
    [ -f "$pkg" ] || return 1
    local body
    while IFS= read -r body; do
        topology_script_is_glue "$body" || return 0
    done < <(jq -r '(.scripts // {}) | to_entries[] | .value' "$pkg" 2>/dev/null)
    return 1
}

# topology_has_workspaces "<package.json-path>" — exit 0 if the manifest declares
# a non-empty `workspaces` (array form or the {packages:[…]} object form).
topology_has_workspaces() {
    local pkg="$1"
    [ -f "$pkg" ] || return 1
    jq -e '
        (.workspaces // empty)
        | if type == "array" then (length > 0)
          elif type == "object" then ((.packages // []) | length > 0)
          else false end
    ' "$pkg" >/dev/null 2>&1
}

# topology_workspace_tool "<target-dir>" — echo the declared workspace tool, if
# any (pnpm|yarn|nx|turbo|lerna), by presence of its marker file. Empty if none.
# (npm/yarn `workspaces` in package.json is detected separately, above.)
topology_workspace_tool() {
    local dir="$1"
    [ -f "$dir/pnpm-workspace.yaml" ] && { printf 'pnpm';  return 0; }
    [ -f "$dir/nx.json" ]            && { printf 'nx';    return 0; }
    [ -f "$dir/turbo.json" ]         && { printf 'turbo'; return 0; }
    [ -f "$dir/lerna.json" ]         && { printf 'lerna'; return 0; }
    return 0
}

# topology_has_lockfile "<dir>" — exit 0 if <dir> holds any package-manager lockfile.
topology_has_lockfile() {
    local d="$1"
    [ -f "$d/package-lock.json" ] || [ -f "$d/npm-shrinkwrap.json" ] \
        || [ -f "$d/pnpm-lock.yaml" ] || [ -f "$d/yarn.lock" ] || [ -f "$d/bun.lockb" ]
}

# topology_children "<target-dir>" — print (one per line) the depth-1 sub-dirs
# that are self-contained packages: own package.json AND own lockfile. Prunes
# node_modules/.git/vendored. Deterministic (sorted). This is the source of the
# "assessment roots" for an undeclared fan-out.
topology_children() {
    local target="$1" d name
    for d in "$target"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        case "$name" in
            node_modules|.git|vendor|third_party|.yarn|dist|build|coverage) continue ;;
        esac
        [ -f "$d/package.json" ] || continue
        topology_has_lockfile "$d" || continue
        printf '%s\n' "$name"
    done | sort
}

# classify_topology <root_pkg> <root_ws> <root_wstool> <root_lock> <root_real> <child_count>
#   root_pkg   : true if a root package.json exists
#   root_ws    : true if root package.json declares non-empty workspaces
#   root_wstool: workspace tool name, or "" / "null"
#   root_lock  : true if the root has its own lockfile
#   root_real  : true if the root has real (non-glue) scripts
#   child_count: number of self-contained child packages
# Echoes: single | declared-workspace | undeclared-fan-out | orphan-root | n/a
# Ordered so DECLARED short-circuits before the fan-out smell (don't cry wolf).
classify_topology() {
    local pkg="$1" ws="$2" wstool="$3" lock="$4" real="$5" children="$6"
    [ "$pkg" = true ] || { echo "n/a"; return 0; }
    [ "$ws" = true ] && { echo "declared-workspace"; return 0; }
    { [ -n "$wstool" ] && [ "$wstool" != "null" ]; } && { echo "declared-workspace"; return 0; }
    if [ "${children:-0}" -ge 2 ] && [ "$lock" != true ] && [ "$real" != true ]; then
        echo "undeclared-fan-out"; return 0
    fi
    { [ "$lock" = true ] || [ "$real" = true ]; } && { echo "single"; return 0; }
    echo "orphan-root"
}
