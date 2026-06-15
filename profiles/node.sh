#!/bin/bash
# Default Node command profile (#6).
#
# These are the literal commands the orchestrator used before the profile layer
# existed, so a Node repo with no overrides behaves identically. `=` means an
# exported CHECKUP_CMD_* (from the environment or, later, a .checkup.yml
# `commands:` block) takes precedence over the default below.
#
# A consumer adapting checkup to another stack drops a sibling profile (e.g.
# profiles/dotnet.sh) that sets the same CHECKUP_CMD_* names to that stack's
# commands; any it leaves unset degrade to an honest skip rather than running a
# Node command.

: "${CHECKUP_CMD_TYPECHECK=npm run typecheck}"
: "${CHECKUP_CMD_TEST=npm test}"
: "${CHECKUP_CMD_FORMAT=npm run format:check}"
: "${CHECKUP_CMD_LINT=npm run lint}"
: "${CHECKUP_CMD_TYPEAWARE=npx eslint -c eslint.config.type-aware.js}"
: "${CHECKUP_CMD_BUILD=npm run build}"
: "${CHECKUP_CMD_DEPS=npm run quality:deps}"
: "${CHECKUP_CMD_UNUSED=npm run quality:unused}"
: "${CHECKUP_CMD_COVERAGE=npm run test:coverage:report}"
: "${CHECKUP_CMD_MUTATION=npx stryker run}"
: "${CHECKUP_CMD_SECURITY=npm run quality:security}"
: "${CHECKUP_CMD_AUDIT=npm audit --json}"
: "${CHECKUP_CMD_OUTDATED=npm outdated --json}"
