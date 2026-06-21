# lib/audit-provenance.jq — npm-audit provenance calibration (plan 0001 §B, #100).
#
# Input:  an `npm audit --json` document.
# Args:   $deps (array of dependencies names), $dev (array of devDependencies
#         names) — read from the relevant package.json.
# Output: { top: [...], crit_nondev, crit_dev, runtime_crit, transitive_crit,
#           high_nondev } for the section to render and to drive status.
#
# Calibration: a critical in a DIRECT devDependency (build-time tooling, not in
# the shipped artifact or runtime attack surface) is genuinely lower urgency than
# one in the production tree. We DOWN-WEIGHT only what we can PROVE is dev — a
# direct dependency listed in devDependencies — by one severity notch, and lead
# the report with runtime risk. A TRANSITIVE vuln is left at face value: npm's
# isDirect=false does not mean dev (it is often a dependency of a runtime
# dependency, i.e. prod-reachable), so we never down-weight it. Honest, not
# alarmist, and never suppressed.

def sevrank: {"critical":0,"high":1,"medium":2,"moderate":2,"low":3,"info":4}[.] // 5;
def downgrade: {"critical":"high","high":"medium","moderate":"low","low":"low","info":"info"}[.] // .;
def norm: {"critical":"critical","high":"high","moderate":"medium","low":"low","info":"info"}[.] // "warning";

[ (.vulnerabilities // {}) | to_entries[]
  | .value as $v
  # Provenance: a direct dep in `dependencies` is runtime; a direct dep in
  # `devDependencies` (and not also a runtime dep) is dev; a direct dep in
  # neither is treated as runtime (conservative — never down-weight on a guess);
  # anything not direct is transitive.
  | ( if ($deps | index($v.name)) then "runtime"
      elif ($v.isDirect == true) and ($dev | index($v.name)) then "dev"
      elif ($v.isDirect == true) then "runtime"
      else "transitive" end ) as $prov
  | ($v.severity) as $raw
  | (if $prov == "dev" then ($raw | downgrade) else $raw end) as $eff
  | { name: $v.name, prov: $prov, raw: $raw,
      file: "package.json", line: 1,
      code: ($v.name + "@" + ($v.range // "?")),
      severity: ($eff | norm),
      message: ( $v.name + " — " + ($raw|tostring)
                 + " [" + $prov + (if $prov == "dev" then ", build-time only" else "" end) + "]"
                 + " (" + (($v.via // []) | map(if type == "string" then . else (.title // "") end) | join(", "))[0:140] + ")" ) }
]
| { # Severity leads (a real transitive/prod critical must top the list), with
    # provenance as the within-band tiebreaker (runtime before transitive before
    # dev). The dev down-weighting above already demotes build-time criticals out
    # of the critical band, so they fall below real criticals naturally.
    top: ( sort_by( (.severity | sevrank), ({"runtime":0,"transitive":1,"dev":2}[.prov] // 3), .code ) | .[0:10] ),
    crit_nondev:     ([ .[] | select(.raw == "critical" and .prov != "dev") ] | length),
    crit_dev:        ([ .[] | select(.raw == "critical" and .prov == "dev") ] | length),
    runtime_crit:    ([ .[] | select(.raw == "critical" and .prov == "runtime") ] | length),
    transitive_crit: ([ .[] | select(.raw == "critical" and .prov == "transitive") ] | length),
    high_nondev:     ([ .[] | select(.raw == "high" and .prov != "dev") ] | length)
  }
