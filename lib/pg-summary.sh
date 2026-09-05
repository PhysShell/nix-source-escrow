# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is a jq program.
#
# policy-governed line -- COMMIT 10, the human-readable summary.
#
# PREREG.md §10 and §16. Two rules, and the second one is the harder one:
#
#   1. the check name states the EXACT guarantee, always
#   2. no marketing claim stronger than the evidence
#
# Rule 2 is not satisfied by adding a caveat somewhere. The closed line learned
# that the hard way and wrote it into its own unit tests: a disclosure a reader
# does not reach is not a disclosure, and position is part of a disclosure.
# So what this line does NOT prove is at the BOTTOM of the summary, where a
# reader who stops early has still passed the verdict -- and it is printed on
# every run, including the green ones. Especially the green ones.

# nse_pg_summary <gate-report.json> [<scratch-report.json>]
nse_pg_summary() {
  local gate=$1 scratch=${2:-}
  local scratch_arg=/dev/null
  [ -n "$scratch" ] && [ -f "$scratch" ] && scratch_arg=$scratch

  nse_pg_jq -r -n \
    --slurpfile g "$gate" \
    --slurpfile s <(if [ "$scratch_arg" = /dev/null ]; then printf 'null\n'; else cat "$scratch_arg"; fi) \
    '
    ($g[0]) as $G | ($s[0]) as $S
    | ($G.decisions) as $D
    | [
      "Policy-governed source escrow",
      "",
      "Candidate:",
      "  dependency content: " + (if $G.digests.dependencyContent == "UNCHANGED" then "unchanged" else "CHANGED" end),
      "  policy facts:       " + (if $G.digests.policyFacts == "UNCHANGED" then "unchanged" else "CHANGED" end),
      "  flake source:       " + (if $G.digests.flakeSource == "UNCHANGED" then "unchanged" else "changed" end),
      "  effective decision: " + (if $G.digests.effectiveDecision == "NOT_COMPUTED" then "not computed"
                                  elif $G.digests.effectiveDecision == "UNCHANGED" then "unchanged"
                                  else "CHANGED" end),
      "",
      "Policy:",
      "  enforced from: " + $G.ENFORCED_POLICY_COMMIT + "  (" + $G.ENFORCED_POLICY_COMMIT_SOURCE + ")",
      "  proposed change: " + (if $G.POLICY_CHANGED == "YES"
                               then "YES -- previewed below, and it governed nothing"
                               else "no" end)
      ]
      + (if $G.POLICY_CHANGED == "YES" and $G.proposedPolicyPreview != null
         then [ "  proposed revision: " + ($G.proposedPolicyPreview.revision // "unparseable"),
                "  verdicts it would move: "
                  + (($G.proposedPolicyPreview.wouldChangeVerdictsFor | length) | tostring) ]
              + [ $G.proposedPolicyPreview.wouldChangeVerdictsFor[]
                  | "    " + (.sourceId | sub("^.*/"; ""))
                    + ": coverage " + (.enforced.coverage // "-") + " -> " + (.proposed.coverage // "-")
                    + ", admission " + (.enforced.admission // "-") + " -> " + (.proposed.admission // "-") ]
         else [] end)
      + [
      "",
      "Sources:",
      "  " + ($D.counts.dependencies | tostring) + " discovered",
      "  " + ([ $D.decisions[] | select(.requiredByPlan == true) ] | length | tostring) + " required by plan",
      "  " + ([ $D.decisions[] | select(.mustPreserve == true) ] | length | tostring) + " must be preserved",
      "  " + ([ $D.decisions[] | .matchedRuleIds[] ] | unique | length | tostring) + " policy rules matched"
      ]
      + (if $D.counts.quarantined > 0
         then [ "  " + ($D.counts.quarantined | tostring) + " QUARANTINED" ] else [] end)
      + (if $D.counts.undecided > 0
         then [ "  " + ($D.counts.undecided | tostring) + " UNDECIDED (policy could not be resolved)" ] else [] end)
      + [
      "",
      "Adversarial controls:"
      ]
      + [ ({id: "JUDGE_MISMATCH",             label: "judge replacement"},
           {id: "WORKFLOW_MISMATCH",          label: "workflow replacement"},
           {id: "POLICY_DEPENDENCY_COCHANGE", label: "policy/dependency cochange"},
           {id: "QUARANTINED_DEPENDENCY",     label: "quarantined dependency"},
           {id: "RULE_CONFLICT",              label: "unresolvable policy"},
           {id: "POLICY_CONFLICT",            label: "annotation weakening policy"})
          | . as $c
          # `[ ... ] | .[0]`, NOT `($G.findings[] | select(...)) as $f`.
          #
          # Binding an EMPTY stream with `as` produces no output at all, so
          # every control that did NOT fire silently vanished from this list --
          # and a summary of adversarial controls that only lists the ones that
          # triggered is a summary that cannot say a guard was considered and
          # found nothing. The absent line reads as "we did not check".
          | ([ $G.findings[] | select(.id == $c.id) ] | .[0]) as $f
          | "  " + $c.label + ": "
            + (if $f == null then "not triggered"
               elif $f.severity == "REJECT" then "REJECTED"
               else "recorded (" + $f.severity + ")" end) ]
      + [
      "",
      "Guarantee:",
      "  " + (if $S == null
             then "NOT RUN in this invocation -- no acceptance test was executed, so no guarantee is claimed."
             else $S.checkName end)
      ]
      + (if $S != null
         then [ "  scratch: local, ephemeral, credential-free; durable promotion: none",
                "  elapsed: " + (($S.elapsedMilliseconds / 1000) | floor | tostring) + "s" ]
         else [] end)
      + [
      "",
      "VERDICT: " + $G.verdict
      ]
      + (if ($G.rejectedBy | length) > 0
         then [ "  rejected by: " + ($G.rejectedBy | join(", ")) ] else [] end)
      + [
      "",
      "What this does NOT establish:",
      "  * NOT a claim that a workflow in this repository provides GitHub-level",
      "    judge independence. The separation proved here is local. Real",
      "    enforcement needs an organization-level required workflow or an",
      "    external trusted judge.",
      "  * NOT a claim about authenticated durable promotion. No byte produced",
      "    by the untrusted candidate phase reached durable storage, because",
      "    this version has no durable storage to reach.",
      "  * The guarantee named above is the one that was run. The two are not",
      "    interchangeable: SOURCE_ORIGIN_INDEPENDENCE escrows source material",
      "    and lets the acceptance test use an approved binary replica;",
      "    ESCROW_REPLAY escrows the whole realised closure and allows nothing",
      "    else."
      ]
      | .[]'
}
