#!/bin/bash
# Command-profile resolution (#6).
#
# Project-built checks (typecheck, test, build, lint, …) used to hardcode
# `npm run <script>`. They now read their command from a *profile*, so adding a
# stack is "drop a profile", not "fork checkup.sh". Cross-stack checks (secrets,
# SAST, forensics, stats, and the complexity/duplication ENGINES) are NOT
# profile-driven and are untouched.
#
# Resolution precedence, highest first:
#   1. CHECKUP_CMD_<NAME> in the environment (an explicit empty value = "no
#      command" → the check degrades to an honest skip)
#   2. the selected stack profile  — profiles/<primary>.sh
#   3. the default Node profile     — profiles/node.sh (applied only when no
#      stack-specific profile was loaded, so a repo with no dedicated profile
#      behaves byte-for-byte as the pre-profile script did)
#
# Profiles set each command with `: "${CHECKUP_CMD_X=…}"` (no colon, so an
# explicitly empty value is preserved as "disabled"), so an environment (or,
# later, a .checkup.yml) value always wins over a profile default.

# Load the profile for the detected primary stack, falling back to the Node
# default profile when there is no stack-specific one.
load_profile() {  # $1 = primary stack id (may be empty), $2 = checkup home dir
    local primary="$1" home="$2" loaded=""
    if [ -n "$primary" ] && [ -f "$home/profiles/$primary.sh" ]; then
        # shellcheck source=/dev/null
        source "$home/profiles/$primary.sh"
        loaded="$primary"
    fi
    if [ -z "$loaded" ]; then
        # shellcheck source=/dev/null
        source "$home/profiles/node.sh"
    fi
}

# Echo the resolved command string for a canonical NAME (e.g. TEST, BUILD).
# Empty output means "no command configured" → the caller skips honestly.
cmd_for() {  # $1 = NAME
    local var="CHECKUP_CMD_$1"
    printf '%s' "${!var-}"
}

# Run a project-built check through its profile command. An UNSET command routes
# through run_tool with a sentinel so LAST_EXIT becomes 127 — exactly the signal
# the sections' existing `toolchain_absent` path treats as "skip, don't pass". A
# SET command is dispatched through run_tool unchanged, so the Node default
# profile reproduces the previous behaviour exactly.
run_profiled() {  # $1 = NAME, $2 = label, [extra args appended to the command]
    local name="$1" label="$2"; shift 2
    local cmd; cmd=$(cmd_for "$name")
    if [ -z "$cmd" ]; then
        run_tool "$label" __checkup_no_command_for_stack__
        return 0
    fi
    # shellcheck disable=SC2086  # intentional word-split of the profile command
    run_tool "$label" $cmd "$@"
}
