# 0010 — Knowledge-concentration (key-person / bus-factor) forensic check

- **Status:** Accepted (2026-07-15)

## Context

checkup's git forensics — `git-hotspots`, `change-coupling`, `bug-fix-density`,
`branch-hygiene` — all measure the **code**: *what* is risky and *where*. None
measure the **people**: *who* holds the code. Yet "what's the bus factor?" is the
number-one non-code question in tech due diligence (ADR-0009 use case 3), and a
cross-training map is exactly the team-prioritisation signal (use case 2). All of
it is derivable from `git log` alone — deterministic, reproducible, zero new
tooling — so it is a natural fit for a front-loaded localiser rather than
something an agent should burn tokens inferring.

The signal is genuinely useful only if a few hard problems are handled honestly,
which is why it warrants a record:

1. **Author identity is the correctness risk.** Ownership is computed by author,
   and one human commits under many identities (`work@`, `personal@`, a CI bot, a
   renamed account) while shared accounts merge many humans into one. Get identity
   wrong and the *headline number is wrong* — this dwarfs every other design
   choice. (A manual precursor run mislabelled a contributor by guessing identity
   from initials; the tool must never guess.)
2. **Lines-added is a noisy proxy.** Generated/vendored files and mass reformats
   or moves inflate authorship. Trusting raw line counts rewards whoever ran the
   codemod.
3. **All-history ≠ maintainable now.** Someone who wrote a subsystem and left is a
   *bigger* continuity risk than a healthy shared area — but a pure all-time
   ownership tally would rank them as a reassuring "owner".
4. **It emits people's names** — PII that is fine in a local, uncommitted report
   but not always in one that gets shared.

## Decision

Add an `ownership` forensic check (slug `ownership`) computed from a single
`git log --numstat` pass over the same scan roots the other forensics use. It
surfaces contribution concentration, the literal bus factor (authors to reach
50% / 80% of the code), sole-authored files, single-owned areas, and
**orphaned knowledge** (sole-owned code whose only author has gone inactive).

Design commitments, each answering a Context problem:

1. **Identity via git's own mailmap resolution, coalesced by email.** We read
   `%aN`/`%aE` (the mailmap-applied forms), so a repo `.mailmap` is honoured for
   free and identities coalesce by canonical email. We do **not** invent our own
   alias heuristics (no initials-matching, no name fuzzing). The summary **always
   carries an identity caveat** — unmerged aliases split one person, shared
   accounts merge many — so the number is never read as more precise than it is.
2. **Commit-touch ownership as primary; lines-added as corroboration.** Per-file
   ownership is decided by how many commits each author landed on the file
   (robust to one-off codemods); lines-added share informs the concentration
   headline. Generated/vendored files are dropped up front by reusing the
   existing source inventory (the same exclude the complexity/duplication engines
   trust) so a committed bundle can't crown its committer.
3. **Recency for the orphaned-knowledge signal.** A sole-authored file whose
   owner has no commit within the recency window is flagged as the sharpest tier —
   this is the *absence-is-signal* case (ADR-0009): nobody active knows it.
4. **`warn`, never `fail`; `skip` when history is too thin.** It is a focus
   signal, not a defect (a non-gate, per ADR-0009) — same posture as
   `change-coupling` and `branch-hygiene`. A non-git tree, a **shallow clone**, or
   too little history degrades to an honest `skip` (ADR-0003), never a false pass.
5. **Optional anonymise mode** (`CHECKUP_OWNERSHIP_ANON=1`) replaces names with
   stable, share-ranked pseudonyms for reports that leave the machine.

Thresholds (`keyperson_pct_warn`, `sole_author_pct_warn`, orphan recency) are
tunable via `.checkup.yml thresholds` and env, defaulting to the literals so an
absent block is byte-identical (the ADR-0002 / #72 convention). The record is
emitted through `write_parsed`/`write_skipped` with an `intent` block; the
tool-agnostic renderer picks it up automatically (ADR-0002).

## Consequences

- A new deterministic **people axis** alongside the code axes, at near-zero cost
  (one extra `git log` walk), directly serving the due-diligence and
  team-prioritisation contexts.
- The headline is only as good as author identity. We mitigate with mailmap +
  email coalescing and a **loud, permanent caveat**, but a repo with unmerged
  aliases will still under-count concentration — documented, not hidden.
- Names in output are PII. Acceptable for a local report (as `branch-hygiene`
  already surfaces author-named branches), with an opt-in anonymise mode for
  shared ones.
- Ownership is tracked as its own continuity facet, **not** averaged into the
  code-quality bands: "one person wrote it well" is a different risk from "it's
  written badly", and conflating them would mislead both readings.
