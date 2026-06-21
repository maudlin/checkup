# Re-aggregate scc `--by-file --format json` to a per-language breakdown, keeping
# only first-party files — the scan-stage cure for "scc measures the whole tree
# while the inventory measures first-party" (plan 0002 / #109).
#
# scc has no file-list input, and its dir/regex `--exclude` cannot express the
# scattered generated/vendored files the inventory classifies. So rather than feed
# scc a list, we let it walk once (`--by-file`) and FILTER + RE-AGGREGATE its
# per-file output against the inventory keep-set. The result mirrors scc's own
# `--format json` language-array shape ({Name, Code, Count, Complexity, Lines}) so
# existing consumers (detect-stacks.jq, codebase-stats) are unchanged — but the
# numbers now reflect the code the team owns, not the whole working tree.
#
# Faithful: summing the kept per-file rows equals scc's own totals over that set
# (verified on corvus: Σ == baseline). Order-invariant: group_by + add do not
# depend on scc's nondeterministic walk order, and the output is given a TOTAL
# order (Code desc, then Name asc) so two runs are byte-identical (#96).
#
# Input  (stdin): scc --by-file --format json
#                 → [ {Name, Files:[{Location, Language, Code, Complexity, Lines, …}], …}, … ]
# Bind   $keep:   via `--slurpfile keep <file>` where <file> is a JSON array of
#                 TARGET-relative first-party paths. (slurpfile wraps it, so we
#                 read $keep[0]; slurpfile — not --argjson — to dodge the ~128KB
#                 argv cap on large keep-sets.)
# Output:         [ {Name, Code, Count, Complexity, Lines} ]  (Code desc, Name asc)
#
# A path's "./" prefix is normalised on both sides so scc's "./foo" and the
# inventory's "foo" share one namespace.

( ($keep[0] // [])
  | map({ key: sub("^\\./"; ""), value: true })
  | from_entries
) as $k
| [ .[].Files[]?
    | select( $k[ (.Location | sub("^\\./"; "")) ] // false )
  ]
| group_by(.Language)
| map({ Name:       .[0].Language,
        Code:       (map(.Code)       | add),
        Count:      length,
        Complexity: (map(.Complexity) | add),
        Lines:      (map(.Lines)      | add) })
| sort_by( -.Code, .Name )
