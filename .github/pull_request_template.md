## What & why

<!-- One or two sentences: what this changes and the motivation. -->

## Type of change

- [ ] New / changed check
- [ ] Bug fix
- [ ] Docs
- [ ] Tooling / CI / image
- [ ] Other:

## Checklist

- [ ] `shellcheck --severity=error bin/*.sh lib/*.sh docker/*.sh test/*.sh` passes
- [ ] `bash -n` clean on changed scripts and `bash test/run-tool.test.sh` passes
- [ ] If adding/altering a check: follows the [contract](../README.md#the-contract) — documented intent, emits via `write_parsed`/`write_skipped`/`write_failed`, degrades gracefully, and **never reads empty tool output as a pass**
- [ ] **No reference to any specific scanned project** (names, real file paths, findings) in code, docs, or commits — this repo is public
- [ ] Docs updated (`README.md` / `ROADMAP.md`) and `CHANGELOG.md` if user-facing
- [ ] British English in docs and comments

## Notes

<!-- Anything reviewers should know: trade-offs, follow-ups, sample report output. -->
