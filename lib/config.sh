#!/bin/bash
# Repo-local override layer — .checkup.yml (the agent-tailoring seam).
#
# checkup auto-detects stacks (#7) and picks default commands (#6); this lets a
# repo owner override those deliberately, with no install step. The detector
# consults this FIRST. Absent file → pure defaults (a no-op). The grammar is a
# deliberately small YAML subset parsed in bash (yq is NOT a dependency; it is
# used only as an accelerator if present). Anything richer → warn and continue;
# never abort, never a false pass.
#
# Supported keys (all optional):
#   stack:
#     force: <id>            # treat this stack as primary (overrides detection)
#     suppress: [a, b]       # treat these stacks as absent (engine routing skips them)
#   checks:
#     disable: [slug, …]     # force a project-built check to skip
#     enable:  [mutation]    # opt in to a check that is off by default
#   commands:                # override the resolved command (see lib/profile.sh)
#     test: "…"  build: "…"  typecheck: "…"  lint: "…"  format: "…"
#     typeaware: "…"  deps: "…"  unused: "…"  coverage: "…"  mutation: "…"
#     security: "…"  audit: "…"  outdated: "…"   # "" disables that command
#   exclude: [glob, …]       # cross-scanner exclude globs (#18) — additive with
#                            # the CHECKUP_EXCLUDE env var; reaches every engine
#                            # (lizard inventory AND scc keep-set, #109). Top-level
#                            # (not nested). Directory globs work: `vendor/js/*`.
#   thresholds:              # per-check warn/fail banding (#72) — integers, with
#     complexity_ccn_warn: 10   #   the historical literals as defaults so an
#     complexity_ccn_fail: 30   #   absent block is byte-identical. Tunes only the
#     duplication_warn_pct: 3   #   status the section already applies (NOT scoring,
#     duplication_fail_pct: 5   #   ADR-0009). Garbage → warn + keep the default.
#
# Grammar: `key: value` and one level of `section:`-nested `  key: value`;
# inline flow lists `[a, b]`; `#` comments; quoted or bare scalars. Block-style
# (`- item`) lists are out of scope on the bash path (use inline `[…]`).
#
# Outputs (consumed by bin/checkup.sh): CHECKUP_FORCE_STACK, CHECKUP_SUPPRESS_STACKS,
# CHECKUP_DISABLE, CHECKUP_ENABLE, CHECKUP_CMD_* (commands), CHECKUP_EXCLUDE
# (merged with the env var), CHECKUP_CPLX_CCN_WARN/FAIL, CHECKUP_DUP_WARN_PCT/FAIL_PCT
# (thresholds), CHECKUP_OVERRIDDEN.

_cfg_trim()   { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
_cfg_unquote(){ # strip one layer of matching single/double quotes
    local s="$1"
    case "$s" in
        \"*\") s="${s#\"}"; s="${s%\"}";;
        \'*\') s="${s#\'}"; s="${s%\'}";;
    esac
    printf '%s' "$s"
}
_cfg_list() { # "[a, \"b c\", d]" → "a" / "b c" / "d" newline-separated
    local s; s="$(_cfg_trim "$1")"; s="${s#[}"; s="${s%]}"
    local IFS=','; local item
    for item in $s; do
        item="$(_cfg_unquote "$(_cfg_trim "$item")")"
        [ -n "$item" ] && printf '%s\n' "$item"
    done
}

# Canonical command keys accepted under `commands:` → CHECKUP_CMD_<UPPER>.
_cfg_cmd_known=" test build typecheck lint format typeaware deps unused coverage mutation security audit outdated "

# _cfg_int <candidate> <default> — echo <candidate> iff it's a non-negative
# integer, else <default>. The use-site guard for thresholds (#72): keeps a bad
# value (from a hand-set env var, or anything the parser let through) from
# reaching jq / `[ -lt ]` — never abort, never a false pass.
_cfg_int() {
    case "$1" in
        ''|*[!0-9]*) printf '%s' "$2";;
        *)           printf '%s' "$1";;
    esac
}

load_checkup_config() {  # $1 = path to .checkup.yml
    local file="$1"
    CHECKUP_OVERRIDDEN="${CHECKUP_OVERRIDDEN:-false}"
    [ -f "$file" ] || return 0

    if command -v yq > /dev/null 2>&1; then
        _cfg_parse_yq "$file" && return 0
        # yq present but file unreadable by it → fall through to the bash parser.
    fi

    local section="" raw key val
    while IFS= read -r raw || [ -n "$raw" ]; do
        raw="${raw%$'\r'}"                              # tolerate CRLF
        case "$(_cfg_trim "$raw")" in ''|'#'*) continue;; esac
        raw="$(printf '%s' "$raw" | sed 's/[[:space:]]#.*$//')"   # strip inline comment
        [ -z "$(_cfg_trim "$raw")" ] && continue

        if [[ "$raw" == [![:space:]]* ]]; then
            # top-level: "section:" or "key: value"
            key="$(_cfg_trim "${raw%%:*}")"; val="$(_cfg_trim "${raw#*:}")"
            if [ -z "$val" ]; then section="$key"; continue; fi
            section=""
            # A top-level scalar/list — only `exclude:` is recognised (other
            # top-level scalars, e.g. a `version:`, are deliberately ignored).
            [ "$key" = "exclude" ] && _cfg_apply toplevel exclude "$val"
        else
            # nested "  key: value"
            local t; t="$(_cfg_trim "$raw")"
            key="$(_cfg_trim "${t%%:*}")"; val="$(_cfg_trim "${t#*:}")"
            _cfg_apply "$section" "$key" "$val"
        fi
    done < "$file"
}

# Apply one nested key:value to the override variables. Unknown keys warn + continue.
_cfg_apply() {  # $1 = section, $2 = key, $3 = raw value
    local section="$1" key="$2" val="$3"
    case "$section" in
        stack)
            case "$key" in
                force)    CHECKUP_FORCE_STACK="$(_cfg_unquote "$val")"; CHECKUP_OVERRIDDEN=true;;
                suppress) CHECKUP_SUPPRESS_STACKS="$(_cfg_list "$val" | tr '\n' ' ')"; CHECKUP_OVERRIDDEN=true;;
                *) echo "⚠️  .checkup.yml: unknown key 'stack.$key' — ignoring" >&2;;
            esac;;
        checks)
            case "$key" in
                disable) CHECKUP_DISABLE="$(_cfg_list "$val" | tr '\n' ' ')"; CHECKUP_OVERRIDDEN=true;;
                enable)  CHECKUP_ENABLE="$(_cfg_list "$val" | tr '\n' ' ')";  CHECKUP_OVERRIDDEN=true;;
                *) echo "⚠️  .checkup.yml: unknown key 'checks.$key' — ignoring" >&2;;
            esac;;
        commands)
            if [[ "$_cfg_cmd_known" == *" $key "* ]]; then
                # An explicit (even empty) value wins; empty = disable that command.
                local up; up="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
                printf -v "CHECKUP_CMD_$up" '%s' "$(_cfg_unquote "$val")"
                export "CHECKUP_CMD_$up"
                CHECKUP_OVERRIDDEN=true
            else
                echo "⚠️  .checkup.yml: unknown command '$key' — ignoring" >&2
            fi;;
        thresholds)
            # Per-check warn/fail banding (#72). Integers only; garbage → warn +
            # keep the default (the use-site `${VAR:-literal}` supplies it). Export
            # so the value also reaches jq via `$ARGS.named` / env at the use site.
            local _tv; _tv="$(_cfg_unquote "$val")"
            local _tvar=""
            case "$key" in
                complexity_ccn_warn)  _tvar=CHECKUP_CPLX_CCN_WARN;;
                complexity_ccn_fail)  _tvar=CHECKUP_CPLX_CCN_FAIL;;
                duplication_warn_pct) _tvar=CHECKUP_DUP_WARN_PCT;;
                duplication_fail_pct) _tvar=CHECKUP_DUP_FAIL_PCT;;
                *) echo "⚠️  .checkup.yml: unknown key 'thresholds.$key' — ignoring" >&2;;
            esac
            if [ -n "$_tvar" ]; then
                if printf '%s' "$_tv" | grep -Eq '^[0-9]+$'; then
                    printf -v "$_tvar" '%s' "$_tv"; export "$_tvar"; CHECKUP_OVERRIDDEN=true
                else
                    echo "⚠️  .checkup.yml: thresholds.$key must be a non-negative integer (got '$_tv') — ignoring" >&2
                fi
            fi;;
        toplevel)
            case "$key" in
                exclude)
                    # Cross-scanner exclude globs (#18) — additive with any env
                    # CHECKUP_EXCLUDE; feeds _inventory_excluded so they reach BOTH
                    # the lizard inventory AND the scc keep-set (#109). Empty → no-op.
                    local globs; globs="$(_cfg_list "$val" | tr '\n' ' ')"; globs="$(_cfg_trim "$globs")"
                    if [ -n "$globs" ]; then
                        CHECKUP_EXCLUDE="$(_cfg_trim "${CHECKUP_EXCLUDE:-} $globs")"
                        export CHECKUP_EXCLUDE; CHECKUP_OVERRIDDEN=true
                    fi;;
                *) echo "⚠️  .checkup.yml: unknown top-level key '$key' — ignoring" >&2;;
            esac;;
        "") echo "⚠️  .checkup.yml: '$key' outside a known section — ignoring" >&2;;
        *)  echo "⚠️  .checkup.yml: unknown section '$section' — ignoring" >&2;;
    esac
}

# yq accelerator: emit the same nested key/value stream the bash parser consumes.
_cfg_parse_yq() {  # $1 = file
    local kv
    kv=$(yq -r '
        (.stack.force      // empty | "stack force " + .),
        (.stack.suppress   // [] | "stack suppress [" + (join(", ")) + "]"),
        (.checks.disable   // [] | "checks disable [" + (join(", ")) + "]"),
        (.checks.enable    // [] | "checks enable ["  + (join(", ")) + "]"),
        (.exclude // [] | select(length > 0) | "toplevel exclude [" + (join(", ")) + "]"),
        (.commands // {} | to_entries[] | "commands " + .key + " " + (.value|tostring)),
        (.thresholds // {} | to_entries[] | "thresholds " + .key + " " + (.value|tostring))
    ' "$file" 2>/dev/null) || return 1
    local sec key val
    while read -r sec key val; do
        [ -z "$sec" ] && continue
        case "$sec $key" in
            "stack suppress"|"checks disable"|"checks enable")
                _cfg_apply "$sec" "$key" "$val";;
            *) _cfg_apply "$sec" "$key" "$val";;
        esac
    done <<< "$kv"
    return 0
}

# Apply check toggles AFTER the profile loads: disabling a project-built check
# empties its command so run_profiled takes the honest skip path (no per-section
# guard needed); enabling flips a check's opt-in gate. Cross-stack/engine checks
# can't be emptied this way — warn rather than pretend.
_cfg_disable_map() {  # slug → space-separated CHECKUP_CMD names (empty if unsupported)
    case "$1" in
        typecheck) echo "TYPECHECK";; unit-tests) echo "TEST";;
        build) echo "BUILD";; code-quality) echo "FORMAT LINT";;
        type-aware-lint) echo "TYPEAWARE";; semgrep) echo "SECURITY";;
        npm-audit) echo "AUDIT";; deps-freshness) echo "OUTDATED";;
        circular-deps) echo "DEPS";; unused-code) echo "UNUSED";;
        coverage) echo "COVERAGE";; mutation) echo "MUTATION";;
        *) echo "";;
    esac
}
apply_check_toggles() {
    local slug names n
    for slug in ${CHECKUP_DISABLE:-}; do
        names="$(_cfg_disable_map "$slug")"
        if [ -z "$names" ]; then
            echo "⚠️  .checkup.yml: cannot disable '$slug' here (cross-stack/engine check, not command-gated) — ignoring" >&2
            continue
        fi
        for n in $names; do printf -v "CHECKUP_CMD_$n" '%s' ''; export "CHECKUP_CMD_$n"; done
    done
    for slug in ${CHECKUP_ENABLE:-}; do
        case "$slug" in
            mutation) export MUTATION_TEST=1;;
            *) echo "⚠️  .checkup.yml: 'enable: $slug' has no opt-in gate — ignoring" >&2;;
        esac
    done
}

# After the checks run, give a disabled (and therefore command-emptied → skipped)
# check an HONEST reason. Without this it would carry the generic "no package.json"
# skip message its section emits, which is misleading on a repo that has one. Only
# touches command-gated slugs we actually emptied, and only if they did skip (so a
# check that somehow ran is never relabelled).
mark_disabled_skips() {  # $1 = parsed dir
    local dir="$1" slug f tmp
    for slug in ${CHECKUP_DISABLE:-}; do
        [ -n "$(_cfg_disable_map "$slug")" ] || continue
        f="$dir/$slug.json"; [ -f "$f" ] || continue
        [ "$(jq -r '.status // empty' "$f" 2>/dev/null)" = "skip" ] || continue
        tmp="$f.tmp"
        jq '.summary = "disabled in .checkup.yml" | .status = "skip"' "$f" > "$tmp" && mv "$tmp" "$f"
    done
}
