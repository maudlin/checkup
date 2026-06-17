# Tornhill CSV row generation (#68) — shared by every complexity slice so the
# row layout has one source of truth and the test can exercise the real thing.
#
# Input: a findings array ({file,line,ccn,code,severity,message}).
# Arg:   $prefix — the engine namespace for the function_id column ("eslint" /
#        "lizard"); purely informational, git-hotspots ignores it.
#
# Emits the canonical lizard CSV columns:
#   NLOC, CCN, token, params, length, function_id, file,
#   function_name, signature, start_line, end_line
# git-hotspots (section 19) reads ONLY column 2 (CCN) and column 7 (file); the
# rest are zero-padded. CYCLOMATIC findings only — cognitive (COG-…) rows are
# dropped here so they never skew the column-2 "CCN" the churn × complexity join
# expects (cognitive still rides in the parsed top[] for display).
.[]
| select(.code | startswith("CCN-"))
| [0, .ccn, 0, 0, 0,
   ($prefix + ":" + .file + "@" + (.line | tostring)),
   .file,
   ((.message | split(" — ")[0])),
   "",
   .line, .line]
| @csv
