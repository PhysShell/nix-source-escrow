# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is a jq or awk program.
#
# policy-governed line -- COMMIT 5, the policy model and the matcher.
#
# PREREG.md §6, §7, §13. Three layers, and the boundaries between them ARE the
# design:
#
#     FACTS      what discovery observed     (lib/pg-facts.sh)
#     POLICY     what the project declared   (this file, first half)
#     DECISION   what the judge concluded    (this file, second half)
#
# and the three sentences this line is not allowed to violate:
#
#     Policy is not evidence.
#     A discovery fact is not policy.
#     A decision is not an observation.

# ---------------------------------------------------------------------------
# THE ORDERED AXES
#
# Each is a total order and an annotation may only move UP it (PREREG.md §7).
# A genuine exemption -- a real `ignore` -- is grantable by the trusted base
# policy and by nothing else.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # consumed by the jq programs below
NSE_PG_JQ_AXES='
def nse_pg_axis_order:
  { coverage:  ["ignore", "auto", "required"],
    retention: ["while-referenced", "permanent"],
    admission: ["normal", "quarantine"] };

def nse_pg_rank($axis; $value):
  (nse_pg_axis_order[$axis]) as $o
  | ($o | index($value))
  # An unknown value on an axis is a POLICY LOAD ERROR, not the bottom of the
  # order. Ranking a typo as the weakest value is how `coverage = "requred"`
  # becomes an exemption nobody wrote.
  | if . == null then error("value \($value) is not on the \($axis) axis. Permitted: \($o | join(", "))") else . end;

# The JOIN: max(base, annotation), per axis, independently.
def nse_pg_join($axis; $base; $ann):
  if $ann == null then $base
  elif nse_pg_rank($axis; $ann) > nse_pg_rank($axis; $base) then $ann
  else $base end;
'

# ---------------------------------------------------------------------------
# SELECTOR WEIGHTS -- declared in PREREG.md §13.1 BEFORE this code existed.
#
# Precedence is NOT TOML order. Depending on file order accidentally works
# until somebody sorts the file, and then a policy changes meaning with no
# diff a reviewer would read as a policy change.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
NSE_PG_JQ_MATCH='
def nse_pg_weights:
  { contentIdentity: 40, aliasPath: 30, repo: 12, owner: 8, originHost: 6, kind: 2 };

def nse_pg_selector_names: (nse_pg_weights | keys);

# Does ONE selector match ONE dependency? THREE outcomes, and the third is
# what PREREG.md §7.3 is about:
#
#   MATCH                  the selector is satisfied
#   NO_MATCH               the fact is known and is something else
#   SELECTOR_FACT_UNKNOWN  the fact was never observed
#
# The third does NOT match. Not permissively, not conservatively -- it does
# not match, the dependency falls through to a less specific rule, and the
# reason is recorded so a policy author can see WHY a rule was inert rather
# than wondering why it never fired.
def nse_pg_selector_result($dep; $sel; $want):
  if $sel == "contentIdentity" then
    ( ($dep.contentIdentity.expectedHash // null) as $eh
    | ($dep.contentIdentity.narHash // null)      as $nh
    | ($dep.contentIdentity.storePath // null)    as $sp
    | if ($want == $eh or $want == $nh or $want == $sp) then "MATCH"
      elif ($eh == null and $nh == null and $sp == null) then "SELECTOR_FACT_UNKNOWN"
      else "NO_MATCH" end )
  elif $sel == "aliasPath" then
    ( if (($dep.aliasPaths // []) | index($want)) != null then "MATCH" else "NO_MATCH" end )
  elif $sel == "kind" then
    ( if ($dep.kind == null) then "SELECTOR_FACT_UNKNOWN"
      elif ($dep.kind == $want) then "MATCH" else "NO_MATCH" end )
  elif ($sel == "owner" or $sel == "repo" or $sel == "originHost") then
    ( ($dep[$sel]) as $f
    | if ($f == null) then "SELECTOR_FACT_UNKNOWN"
      elif (($f.source // "UNKNOWN") == "UNKNOWN") then "SELECTOR_FACT_UNKNOWN"
      elif ($f.value == $want) then "MATCH"
      else "NO_MATCH" end )
  else error("unknown selector \($sel). The selector set is fixed by PREREG.md §13 and is not grown at read time.")
  end;

# `$s` is bound BEFORE the pipe, and that is not style. `A | has(.)` rebinds
# `.` to A, so `has(.)` asks whether the match object has ITSELF as a key --
# which jq reports as "Cannot check whether object has a object key" from a
# line number that points nowhere useful. Two bugs in this file were this exact
# shape, and both of them were silent until jq refused outright.
def nse_pg_rule_selectors($rule):
  [ nse_pg_selector_names[] as $s | select(($rule.match // {}) | has($s)) | $s ];

def nse_pg_specificity($rule):
  [ nse_pg_rule_selectors($rule)[] | nse_pg_weights[.] ] | add // 0;

def nse_pg_rule_match($dep; $rule):
  ( nse_pg_rule_selectors($rule) ) as $sels
  | [ $sels[] | { selector: ., result: nse_pg_selector_result($dep; .; $rule.match[.]) } ] as $results
  | { ruleId: $rule.id,
      specificity: nse_pg_specificity($rule),
      selectors: $results,
      unknownFacts: [ $results[] | select(.result == "SELECTOR_FACT_UNKNOWN") | .selector ],
      # A rule with NO selectors matches everything at specificity 0. That is
      # the declared default rule, and writing one deliberately is a different
      # thing from getting one by typing a selector name wrong -- which the
      # reader below refuses outright.
      matched: ($results | all(.result == "MATCH")) };

# Resolve ONE axis. PREREG.md §13.1, step by step. Step 3 is the one that
# matters: a tie assigning DIFFERENT values fails closed. Not "last wins",
# which makes the verdict a function of file order; and not "most restrictive
# wins", which is a silent join hiding a policy the author did not write.
def nse_pg_resolve_axis($axis; $matches; $rules; $default):
  [ $matches[] | select(.matched)
    | . as $m | ($rules[] | select(.id == $m.ruleId)) as $r
    | select($r | has($axis))
    | { ruleId: $r.id, specificity: $m.specificity, value: $r[$axis] } ] as $c
  | if ($c | length) == 0 then
      { value: $default, wonBy: null, source: "DEFAULT", contenders: [], detail: null }
    else
      ([ $c[].specificity ] | max) as $top
      | [ $c[] | select(.specificity == $top) ] as $top_rules
      | ([ $top_rules[].value ] | unique) as $values
      | if ($values | length) > 1 then
          { value: null, wonBy: null, source: "RULE_CONFLICT",
            contenders: $top_rules,
            detail: "rules \([ $top_rules[].ruleId ] | sort | join(", ")) tie at specificity \($top) and assign different \($axis) values (\($values | join(", "))). PREREG.md §13.1 step 3: this fails closed." }
        else
          { value: $values[0],
            wonBy: ([ $top_rules[].ruleId ] | sort | .[0]),
            source: "RULE",
            contenders: $top_rules, detail: null }
        end
    end;
'

nse_pg_policy_prelude() { printf '%s\n%s\n' "$NSE_PG_JQ_AXES" "$NSE_PG_JQ_MATCH"; }

# ---------------------------------------------------------------------------
# THE TOML READER
#
# A deliberately SMALL subset, and everything outside it is a hard error.
#
# That is the security property, not a limitation to apologise for. A reader
# that ignores what it does not understand reads this
#
#     [[rule]]
#     id = "r1"
#     ownr = "NixOS"          # a typo
#     coverage = "ignore"
#
# as a rule with NO selectors: specificity 0, matching EVERY dependency, and
# exempting all of them. Ignoring an unrecognised key is how a typo becomes a
# blanket exemption. Unknown table, unknown key, unparseable line, control
# character -- every one of them is POLICY_PARSE_ERROR.
#
# Records are UNIT-SEPARATED, not tab-separated. Tab is IFS whitespace, a
# shell read collapses runs of it, and that cost this repository a real defect
# once: an empty field vanished and every value after it shifted one column.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
NSE_PG_AWK_TOML='
function fail(msg) { printf("POLICY_PARSE_ERROR line %d: %s\n", NR, msg) > "/dev/stderr"; exit 3 }
function emit(tbl, idx, key, type, val) { printf("%s\037%d\037%s\037%s\037%s\n", tbl, idx, key, type, val) }
function unquote(v,   s) {
  if (v !~ /^".*"$/) fail("value " v " is not a double-quoted string. This subset accepts double-quoted strings, integers and true/false, and nothing else.")
  s = substr(v, 2, length(v) - 2)
  if (s ~ /\\/) fail("backslash escapes are not accepted in this policy subset")
  if (s ~ /"/)  fail("embedded quote in " v)
  return s
}
BEGIN { table = ""; idx = -1; ok = 0 }
{
  if ($0 ~ /[\001-\010\013\014\016-\037]/) fail("control character in the policy file")
  line = $0
  sub(/[ \t]*#.*$/, "", line)
  gsub(/^[ \t]+|[ \t]+$/, "", line)
  if (line == "") next
  if (line ~ /^\[\[[A-Za-z][A-Za-z0-9_]*\]\]$/) {
    t = substr(line, 3, length(line) - 4)
    if (t != "rule") fail("[[" t "]] is not a table this reader knows. The only array table is [[rule]].")
    table = "rule"; idx++; emit("rule", idx, "__present", "b", "true"); ok = 1; next
  }
  if (line ~ /^\[[A-Za-z][A-Za-z0-9_]*\]$/) {
    t = substr(line, 2, length(line) - 2)
    if (t != "defaults" && t != "governance") fail("[" t "] is not a table this reader knows. Permitted: [defaults], [governance], [[rule]].")
    table = t; ok = 1; next
  }
  if (line ~ /^[A-Za-z][A-Za-z0-9_]*[ \t]*=/) {
    eq = index(line, "=")
    key = substr(line, 1, eq - 1); val = substr(line, eq + 1)
    gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
    # A bare key before any table header belongs to a ROOT pseudo-table, and
    # it must NOT touch the [[rule]] index. Sharing one counter made rule
    # numbering depend on whether a top-level key happened to appear first --
    # a rule id is provenance, and provenance whose numbering shifts with an
    # unrelated line is not provenance.
    if (table == "") { table = "__root"; rootseen = 1 }
    thisidx = (table == "__root") ? 0 : idx
    if (val == "true" || val == "false") emit(table, thisidx, key, "b", val)
    else if (val ~ /^-?[0-9]+$/)         emit(table, thisidx, key, "i", val)
    else                                 emit(table, thisidx, key, "s", unquote(val))
    ok = 1; next
  }
  fail("cannot parse: " line)
}
END {
  # An EMPTY policy file is not a policy that permits everything. Expected
  # non-empty, observed zero -> read failure. The standing rule here.
  if (!ok) { printf("POLICY_PARSE_ERROR: this policy file yielded no directives at all. An unreadable or empty policy is not a policy that governs nothing.\n") > "/dev/stderr"; exit 3 }
}
'

# nse_pg_policy_load <file> [<revision>]
#   stdout: the policy as JSON
#   POLICY_PARSE_ERROR is a CHECKER_ERROR-class failure, never a verdict.
nse_pg_policy_load() {
  local file=$1 revision=${2:-UNKNOWN}
  [ -f "$file" ] || nse_pg_checker_error "no policy file at $file. A missing policy is not an empty policy."
  local records
  records=$(awk "$NSE_PG_AWK_TOML" "$file") \
    || nse_pg_checker_error "POLICY_PARSE_ERROR while reading $file (the reason is above).
       Refusing to continue: a policy this reader cannot fully understand must
       not be applied partially. An ignored key is how a typo becomes a
       blanket exemption."
  printf '%s\n' "$records" | nse_pg_jq -R -s --arg rev "$revision" '
    def known_axes: ["coverage", "retention", "admission"];
    def known_selectors: ["contentIdentity", "aliasPath", "repo", "owner", "originHost", "kind"];
    def known_governance: ["judgeOnMismatch", "workflowOnMismatch", "policyDependencyCochange"];
    def typed($t; $v): if $t == "b" then ($v == "true") elif $t == "i" then ($v | tonumber) else $v end;

    [ split("\n")[] | select(length > 0) | split("")
      | { table: .[0], idx: (.[1] | tonumber), key: .[2], type: .[3], value: .[4] } ] as $rec

    | ( [ $rec[] | select(.table == "__root") ] ) as $root
    | ( [ $rec[] | select(.table == "defaults") ] ) as $defaults
    | ( [ $rec[] | select(.table == "governance") ] ) as $gov
    | ( [ $rec[] | select(.table == "rule") ] ) as $rules

    | ( [ $root[] | select(.key != "schemaVersion") | .key ] ) as $badRoot
    | if ($badRoot | length) > 0 then
        error("unknown top-level key(s): \($badRoot | join(", ")). Permitted: schemaVersion.") else . end
    | ( [ $defaults[] | select(.key as $k | (known_axes | index($k)) == null) | .key ] ) as $badDefaults
    | if ($badDefaults | length) > 0 then
        error("unknown key(s) in [defaults]: \($badDefaults | join(", ")). Permitted: \(known_axes | join(", ")).") else . end
    | ( [ $gov[] | select(.key as $k | (known_governance | index($k)) == null) | .key ] ) as $badGov
    | if ($badGov | length) > 0 then
        error("unknown key(s) in [governance]: \($badGov | join(", ")). Permitted: \(known_governance | join(", ")).") else . end
    | ( [ $rules[] | select(.key != "__present") | select(.key != "id")
          | select(.key as $k | (known_axes | index($k)) == null)
          | select(.key as $k | (known_selectors | index($k)) == null) | .key ] ) as $badRule
    | if ($badRule | length) > 0 then
        error("unknown key(s) in [[rule]]: \($badRule | unique | join(", ")). Permitted: id, \(known_selectors | join(", ")), \(known_axes | join(", ")).") else . end

    | ( [ $rules[] | .idx ] | unique ) as $idxs
    | ( [ $idxs[] as $i
          | ( [ $rules[] | select(.idx == $i) ] ) as $r
          | ( [ $r[] | select(.key == "id") ] | .[0] ) as $id
          | if $id == null then
              error("[[rule]] number \($i + 1) has no id. Rule ids are mandatory (PREREG.md §13): a rule with no id cannot appear in a decision as provenance.")
            else . end
          | { id: $id.value,
              # Declared order is RECORDED but never USED. It is here so a
              # human can find the rule in the file; a unit test asserts that
              # shuffling the file does not move a single verdict.
              declaredOrder: $i,
              match: ( [ $r[] | select(.key as $k | (known_selectors | index($k)) != null)
                         | { key: .key, value: typed(.type; .value) } ] | from_entries ) }
            + ( [ $r[] | select(.key as $k | (known_axes | index($k)) != null)
                  | { key: .key, value: .value } ] | from_entries ) ] ) as $ruleObjs

    | ( [ $ruleObjs[].id ] ) as $ids
    | if ($ids | length) != ($ids | unique | length) then
        error("duplicate rule id(s): \($ids | group_by(.) | map(select(length > 1) | .[0]) | join(", ")). An id is the provenance a decision carries; two rules sharing one make that provenance a lie.")
      else . end

    | { schemaVersion: ( [ $root[] | select(.key == "schemaVersion") | (.value | tonumber) ] | .[0] // 1 ),
        revision: $rev,
        defaults: ( { coverage: "auto", retention: "while-referenced", admission: "normal" }
                    + ( [ $defaults[] | { key: .key, value: .value } ] | from_entries ) ),
        governance: ( { judgeOnMismatch: "reject",
                        workflowOnMismatch: "reject",
                        policyDependencyCochange: "reject" }
                      + ( [ $gov[] | { key: .key, value: typed(.type; .value) } ] | from_entries ) ),
        rules: $ruleObjs }'
}

# ---------------------------------------------------------------------------
# THE MATCHER -- FACTS + POLICY -> DECISIONS
#
#   nse_pg_decide <facts.json> <policy.json>
# ---------------------------------------------------------------------------
nse_pg_decide() {
  local facts=$1 policy=$2
  nse_pg_jq -n --slurpfile f "$facts" --slurpfile p "$policy" \
    "$(nse_pg_policy_prelude)"'
    ($f[0]) as $F | ($p[0]) as $P | ($P.rules) as $rules | ($P.defaults) as $D

    | [ $F.dependencies[] as $dep
        | ( [ $rules[] | nse_pg_rule_match($dep; .) ] ) as $matches
        | ( nse_pg_resolve_axis("coverage";  $matches; $rules; $D.coverage)  ) as $cov
        | ( nse_pg_resolve_axis("retention"; $matches; $rules; $D.retention) ) as $ret
        | ( nse_pg_resolve_axis("admission"; $matches; $rules; $D.admission) ) as $adm
        | ( $dep.annotation // {} ) as $ann
        | { sourceId: $dep.id,
            class: $dep.class,
            requiredByPlan: $dep.requiredByPlan,
            trustedPolicyRevision: $P.revision,
            matchedRuleIds: ( [ $matches[] | select(.matched) | .ruleId ] | sort ),
            axisWonBy: { coverage: $cov.wonBy, retention: $ret.wonBy, admission: $adm.wonBy },
            axisSource: { coverage: $cov.source, retention: $ret.source, admission: $adm.source },
            # WHY a rule did not fire is as useful as why one did. A policy
            # author whose rule is inert should not have to guess.
            unmatchedForUnknownFact:
              [ $matches[] | select(.matched | not) | select((.unknownFacts | length) > 0)
                | { ruleId: .ruleId, selectors: .unknownFacts } ],
            base: { coverage: $cov.value, retention: $ret.value, admission: $adm.value },
            annotation: { coverage: ($ann.coverage // null),
                          retention: ($ann.retention // null),
                          admission: ($ann.admission // null) },
            # Parenthesised because jq requires it: an object VALUE may not be
            # a bare `A + B`, and the compile error it gives instead points at
            # the object key three lines up.
            conflicts: (
              # RULE_CONFLICT is a POLICY defect, and fails closed.
              [ ({axis:"coverage", a:$cov}, {axis:"retention", a:$ret}, {axis:"admission", a:$adm})
                | select(.a.source == "RULE_CONFLICT")
                | { kind: "RULE_CONFLICT", axis: .axis, detail: .a.detail } ]
              +
              # POLICY_CONFLICT is a CANDIDATE overreach: an annotation trying
              # to move DOWN an axis. Recorded, and the base value stands.
              [ ( {axis:"coverage",  b:$cov.value, n:($ann.coverage  // null)},
                  {axis:"retention", b:$ret.value, n:($ann.retention // null)},
                  {axis:"admission", b:$adm.value, n:($ann.admission // null)} )
                | select(.n != null) | select(.b != null)
                | select(nse_pg_rank(.axis; .n) < nse_pg_rank(.axis; .b))
                | { kind: "POLICY_CONFLICT", axis: .axis,
                    detail: "a source annotation asked for \(.n) on the \(.axis) axis where the trusted base policy says \(.b). An annotation may only strengthen; the base value stands." } ] ) }
        | . + { effective:
                  (if ([ .conflicts[] | select(.kind == "RULE_CONFLICT") ] | length) > 0
                   then { coverage: null, retention: null, admission: null }
                   else { coverage:  nse_pg_join("coverage";  .base.coverage;  .annotation.coverage),
                          retention: nse_pg_join("retention"; .base.retention; .annotation.retention),
                          admission: nse_pg_join("admission"; .base.admission; .annotation.admission) }
                   end) }
        | . + { # Coverage semantics, stated once, in the code that applies them:
                #   required  preserve it, whether or not the plan reached it
                #   auto      preserve it if the build plan actually used it
                #   ignore    do not preserve it -- and ONLY the trusted base
                #             policy can put an axis here
                mustPreserve:
                  (if .effective.coverage == "required" then true
                   elif .effective.coverage == "auto" then
                     # NOT `.requiredByPlan == true`. jq evaluates `null ==
                     # true` to FALSE, so a requiredByPlan the run could not
                     # OBSERVE arrived here as "the plan did not use it" --
                     # which under `auto` is an exemption, granted by an
                     # instrument that failed rather than by a policy that
                     # said so. The standing rule of this repository, one
                     # layer further in: UNKNOWN is not EMPTY, and it is not
                     # false either.
                     (if .requiredByPlan == null then null else .requiredByPlan end)
                   elif .effective.coverage == "ignore" then false
                   else null end),
                acceptance:
                  (if .effective.admission == null then "UNDECIDED"
                   elif .effective.admission == "quarantine" then "quarantined"
                   else "accepted" end) } ]
    | { schemaVersion: 1,
        kind: "policy-governed-decisions",
        trustedPolicyRevision: $P.revision,
        decisions: .,
        counts: {
          dependencies: length,
          mustPreserve:    ([ .[] | select(.mustPreserve == true) ] | length),
          quarantined:     ([ .[] | select(.acceptance == "quarantined") ] | length),
          ruleConflicts:   ([ .[] | .conflicts[] | select(.kind == "RULE_CONFLICT") ] | length),
          policyConflicts: ([ .[] | .conflicts[] | select(.kind == "POLICY_CONFLICT") ] | length),
          undecided:       ([ .[] | select(.mustPreserve == null) ] | length)
        } }'
}
