# scc-concentration.jq — single-directory concentration caveat (plan 0002 §6.5,
# #117 Phase 3). The detector for MARKERLESS flat-vendored code that no generated
# marker announces and no convention dir catches (the dotCMS class: a committed
# JS library tree sitting in the first-party keep-set, skewing identity). Too fuzzy
# to auto-exclude — surfaced as a BANNER that names the directory and prints the
# one-line fix, never a silent drop.
#
# LANGUAGE-AWARE, not raw share: the spike (§9) showed the tell is a dir dominated
# by a language FOREIGN to the repo's primary (dotCMS: webapp/html/js is JavaScript
# while the codebase is Java). Pure share alone flags the primary SOURCE directory
# on any normal repo (it is the largest dir) — a false positive that would fire
# everywhere. So a directory is a candidate only when its dominant language differs
# from the repo's dominant language: that is what "vendored-looking" means here.
#
# Input:  scc --by-file --format json (array of language objects, each .Files[]).
# Args:   --slurpfile keep <keepfile>  (JSON array of TARGET-relative keep paths,
#                                        ALL extensions — same set as scc-aggregate)
#         --argjson pct <int>          (threshold percent of total code, e.g. 25)
# Output: the most-SPECIFIC (depth-maximal) directory whose share of the kept code
#         is ≥ pct AND whose dominant language ≠ the repo's, as
#         { dir, code, files, totalCode, pct, lang, repoLang }, or null.
#
# Depth-maximal, not share-maximal: a vendored tree's own subdirs each fall below
# the threshold while the tree's own root is the deepest prefix still above it — so
# "deepest ≥ threshold" names the vendored ROOT (e.g. .../webapp/html/js), the most
# precise exclude path, rather than a shallow ancestor that also sweeps in siblings.
# Deterministic (#96): sort by [depth, share, dir], take the last.

( ($keep[0] // []) | map({ key: sub("^\\./"; ""), value: true }) | from_entries ) as $k
| [ .[].Files[]?
    | { loc: (.Location | sub("^\\./"; "")), code: (.Code // 0), lang: (.Language // "") }
    | select( $k[.loc] // false ) ]                                   as $files
| ( $files | map(.code) | add // 0 )                                  as $total
| if $total <= 0 then null
  else
    # The repo's dominant language (by kept code) — the baseline a candidate dir
    # must differ from to read as "vendored-looking".
    ( $files | group_by(.lang)
             | map({ lang: .[0].lang, code: (map(.code) | add) })
             | sort_by([ -.code, .lang ]) | .[0].lang )               as $repoLang
    | ( $files
        | map( . as $f
               | ($f.loc | split("/"))                               as $parts
               | ($parts[0:-1])                                       as $dirs   # drop the filename
               | [ range(1; ($dirs|length)+1) as $n
                   | { dir: ($dirs[0:$n] | join("/")), code: $f.code, lang: $f.lang } ] )
        | add // []
        | group_by(.dir)
        | map( { dir: .[0].dir,
                 code:  (map(.code) | add),
                 files: length,
                 share: ((map(.code) | add) / $total),
                 # this dir's own dominant language
                 lang:  ( group_by(.lang)
                          | map({ lang: .[0].lang, code: (map(.code) | add) })
                          | sort_by([ -.code, .lang ]) | .[0].lang ) } )
        | map( select( .share >= ($pct / 100) and .files >= 2 and .lang != $repoLang ) )
        | sort_by( [ (.dir | split("/") | length), .share, .dir ] )
        | last )                                                      as $top
    | if $top == null then null
      else { dir: $top.dir, code: $top.code, files: $top.files,
             totalCode: $total, pct: (($top.share * 100) | floor),
             lang: $top.lang, repoLang: $repoLang }
      end
  end
