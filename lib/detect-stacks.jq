# Stack detection (#7): reduce an scc `--format json` language array to a
# per-stack summary, dominant-first. Shared by bin/checkup.sh and test/detect.test.sh
# so the transformation has one source of truth. Input: scc's array of
# {Name, Code, …}. Output: [{stack, code, top3, pct}], sorted by code desc.
#   - stack: the family a language rolls up to (node/python/dotnet/…); languages
#     with no mapping are dropped (they don't drive engine selection).
#   - pct:  integer percent of total mapped+unmapped code (floor).
#   - top3: is any of the stack's languages among the three largest by code?
def stackOf:
  {"TypeScript":"node","JavaScript":"node","JSX":"node","TSX":"node","Svelte":"node","Vue":"node",
   "Python":"python","C#":"dotnet","F#":"dotnet","Go":"go","Java":"java","Kotlin":"java",
   "Ruby":"ruby","PHP":"php","Rust":"rust"}[.];
(map(.Code) | add) as $total
| (if ($total // 0) == 0 then 1 else $total end) as $denom
| (sort_by(-.Code) | .[0:3] | map(.Name)) as $top3
| [ .[] | {name: .Name, code: .Code, stack: (.Name | stackOf)} | select(.stack != null) ]
| group_by(.stack)
| map(.[0].stack as $s | (map(.code) | add) as $c
      | {stack: $s, code: $c,
         top3: (any(.[]; .name as $n | ($top3 | index($n)) != null)),
         pct: (($c * 100 / $denom) | floor)})
| sort_by(-.code)
