# ownership.jq — knowledge-concentration / key-person (bus-factor) transform
# (ADR-0010, #127). The PEOPLE axis of the git forensics: given per-(file,author)
# authorship rows, localise where knowledge concentrates in one person.
#
# Kept as a pure jq transform (no git) so it is unit-testable from fixture rows —
# the "one shared transform, env-independent test" pattern (lib/source-inventory.sh,
# lib/detect-stacks.jq). bin/checkup.sh does the git log + awk normalise and feeds
# the rows here; identity correctness (mailmap, email-coalescing) is settled BEFORE
# this stage — the caller reads git's mailmap-applied %aN/%aE, we never guess.
#
# Input:  newline-delimited TSV rows on stdin (via -R -s), one per (file, author):
#           file \t email \t name \t commits \t added \t lastCommitTs
#         `commits` = commits by that author touching that file; `added` = lines
#         added; `lastCommitTs` = epoch of that author's most recent touch of it.
#         Generated/vendored files are already excluded by the caller (inventory).
# Args:   --argjson now <epoch>          current time, for the recency test
#         --argjson keypersonPct <int>   top-author share (%) that warns (e.g. 50)
#         --argjson solePct <int>        single-author-file rate (%) that warns
#         --argjson orphanDays <int>     sole author idle ≥ this many days → orphaned
#         --argjson areaDepth <int>      path components that define an "area" (e.g. 1)
#         --arg anon <"0"|"1">           replace names with share-ranked pseudonyms
#         --arg hasMailmap <"0"|"1">     whether the repo carries a .mailmap (caveat)
# Output: { status, count, summary, findings } — status capped at warn (never fail),
#         count = number of warning-tier findings; findings mirror the git-hotspots
#         {file,line,code,severity,message} shape so the renderer picks them up.
#
# Metric choice (ADR-0010): per-file ownership is decided by COMMIT touches (robust
# to one-off codemods); the concentration headline uses lines-added share, falling
# back to commits when a window added no lines. Deterministic throughout: every
# sort carries an explicit tie-break (email/file/area) so runs are byte-identical.

# Display name: real name, or a stable share-ranked pseudonym under anonymise mode.
def disp($name; $rank): if $anon == "1" then "Contributor \($rank)" else $name end;

[ split("\n")[] | select(length > 0) | split("\t")
  | { file: .[0], email: (.[1] | ascii_downcase), name: .[2],
      commits: (.[3] | tonumber), added: (.[4] | tonumber), ts: (.[5] | tonumber) } ] as $rows
| if ($rows | length) == 0 then
    { status: "skip", count: 0, summary: "no authored source history in scope", findings: [] }
  else

# --- whole-repo author aggregates ---
( $rows | group_by(.email)
  | map({ email: .[0].email,
          name:  (sort_by([-.ts, -.commits])[0].name),
          added: (map(.added) | add),
          commits: (map(.commits) | add),
          last:  (map(.ts) | max) }) ) as $authors
| ($authors | length) as $authorCount
| ($authors | map(.added) | add) as $totalAdded
| ($rows | map(.commits) | add) as $totalCommits
# Concentration basis: lines-added is the natural "share of the code", but a window
# of pure moves/deletes can zero it out — fall back to commit share so the headline
# is never divide-by-zero and never silently empty.
| (if $totalAdded > 0 then "added" else "commits" end) as $basis
| (if $basis == "added" then $totalAdded else $totalCommits end) as $totalMetric
| ($authors | map(. + { metric: (if $basis == "added" then .added else .commits end) })
            | sort_by([-.metric, .email]) ) as $auth
# email -> rank (1-based, by contribution) for stable anonymised pseudonyms
| (reduce range(0; ($auth | length)) as $i ({}; . + { ($auth[$i].email): ($i + 1) })) as $rank

# Bus factor: fewest authors whose combined metric first reaches $pct% of the total.
| def busFactor($pct):
    ($auth | map(.metric)) as $m
    | reduce range(0; ($m | length)) as $i ({ acc: 0, k: 0, hit: false };
        if .hit then . else
          { acc: (.acc + $m[$i]), k: ($i + 1),
            hit: (((.acc + $m[$i]) * 100) >= ($totalMetric * $pct)) }
        end)
    | (if .hit then .k else ($m | length) end);
  busFactor(50) as $bf50
| busFactor(80) as $bf80
| $auth[0] as $kp
| (($kp.metric * 100) / $totalMetric) as $kpShare
| (($kp.commits * 100) / $totalCommits) as $kpCommitShare
| ($kpShare >= $keypersonPct) as $kpWarn

# --- per-file ownership (commit-touch based) ---
| ( $rows | group_by(.file)
    | map({ file: .[0].file,
            fileCommits: (map(.commits) | add),
            authors: (group_by(.email)
                      | map({ email: .[0].email,
                              name: (sort_by([-.ts])[0].name),
                              commits: (map(.commits) | add),
                              last: (map(.ts) | max) })) })
    | map(. + { owner: (.authors | sort_by([-.commits, .email])[0]),
                sole:  ((.authors | length) == 1) }) ) as $files
| ($files | length) as $fileCount
| ($files | map(select(.sole)) | length) as $soleCount
| (($soleCount * 100) / $fileCount) as $soleRate

# --- orphaned knowledge: sole-owned files whose only author has gone quiet ---
| ($now - ($orphanDays * 86400)) as $orphanCut
| ( $files | map(select(.sole and (.owner.last < $orphanCut)))
           | sort_by([.owner.last, .file]) ) as $orphans
| ($orphans | length) as $orphanCount

# --- per-area concentration: which directories one person dominates ---
| ( $rows
    | map(. + { area: ((.file | split("/")) as $p
                       | if ($p | length) <= $areaDepth then .file
                         else ($p[0:$areaDepth] | join("/")) end) })
    | group_by(.area)
    | map({ area: .[0].area,
            areaCommits: (map(.commits) | add),
            files: (map(.file) | unique | length),
            owners: (group_by(.email)
                     | map({ email: .[0].email, name: (sort_by([-.ts])[0].name),
                             commits: (map(.commits) | add) })
                     | sort_by([-.commits, .email])) })
    | map(. + { top: .owners[0], topShare: ((.owners[0].commits * 100) / .areaCommits) })
    | map(select(.files >= 3 and (.topShare >= $solePct)))
    | sort_by([-(.files), -.topShare, .area]) ) as $areas

# --- findings (tier order: key-person, sole-rate, orphaned, single-owned areas) ---
| ( [ { file: "", line: 1, code: "key-person",
        severity: (if $kpWarn then "warning" else "info" end),
        message: (disp($kp.name; 1) + " authored " + (($kpShare | floor) | tostring)
                  + "% of the code (" + (($kpCommitShare | floor) | tostring)
                  + "% of commits); bus factor " + ($bf50 | tostring) + " to 50% / "
                  + ($bf80 | tostring) + " to 80%, across " + ($authorCount | tostring)
                  + " authors") } ]
    + (if $soleRate >= $solePct then
         [ { file: "", line: 1, code: "sole-authorship", severity: "warning",
             message: (($soleCount | tostring) + " of " + ($fileCount | tostring)
                      + " files (" + (($soleRate | floor) | tostring)
                      + "%) have a single author — bus-factor-1 files") } ]
       else [] end)
    + ($orphans[0:10] | map(
        { file: .file, line: 1, code: "orphaned-knowledge", severity: "warning",
          message: ("sole author " + disp(.owner.name; ($rank[.owner.email] // 0))
                    + " inactive " + ((($now - .owner.last) / 86400) | floor | tostring)
                    + " days — no active maintainer") }))
    + ($areas[0:8] | map(
        { file: .area, line: 1, code: "single-owned-area", severity: "low",
          message: (disp(.top.name; ($rank[.top.email] // 0)) + " owns "
                    + ((.topShare | floor) | tostring) + "% of " + (.files | tostring)
                    + " files in this area") })) ) as $findings

| ($findings | map(select(.severity == "warning")) | length) as $warnCount
| { status: (if $warnCount > 0 then "warn" else "pass" end),
    count: $warnCount,
    summary: ("bus factor " + ($bf50 | tostring) + " — top author holds "
              + (($kpShare | floor) | tostring) + "% of the code across "
              + ($authorCount | tostring) + " authors; "
              + (($soleRate | floor) | tostring) + "% single-author files"
              + (if $orphanCount > 0 then ", " + ($orphanCount | tostring) + " orphaned" else "" end)
              + ". Identity is "
              + (if $hasMailmap == "1" then ".mailmap-resolved" else "email-coalesced (no .mailmap)" end)
              + "; unmerged aliases split a person and shared accounts merge many — verify before quoting."),
    findings: ($findings[0:20]) }
  end
