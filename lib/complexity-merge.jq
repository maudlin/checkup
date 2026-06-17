# Complexity merge (#68): fold the findings from one OR more engine slices
# (ESLint on the JS/TS slice, lizard on the non-JS slice) into the shared record
# fields. One source of truth, used by both bin/checkup.sh and
# test/complexity-merge.test.sh so the merge can't drift between them.
#
# Input: a single flat array of findings, each
#   {file, line, ccn, code, severity, message}
# Slices are partitioned by file extension upstream, so a file never appears
# from two engines — concatenation needs no dedup. `.ccn` carries the score used
# for ranking, the CSV column 2, and the status bands (cyclomatic CCN for both
# engines; ESLint cognitive findings ride along with their cognitive score in
# `.ccn` and code "COG-…", so they rank and display but are filtered OUT of the
# Tornhill CSV by the caller — cognitive must not skew the churn × CCN join).
#
# Output: { count, highest, status, top } —
#   count   : total findings
#   highest : max score (0 when empty)
#   status  : pass when empty; fail when any score ≥ 30; warn otherwise
#   top     : ranked by score desc, capped at 20, with the internal `.ccn` sort
#             key shed so the public top[] schema stays {file,line,code,severity,message}
{
  count:   length,
  highest: (([.[].ccn] | max) // 0),
  status:  (if length == 0 then "pass"
            elif (([.[].ccn] | max) // 0) >= 30 then "fail"
            else "warn" end),
  top:     (sort_by(-.ccn) | .[0:20] | map(del(.ccn)))
}
