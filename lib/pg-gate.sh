# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is a jq program handed
# to nse_pg_jq.
#
# policy-governed line -- COMMIT 6, the trusted-root / candidate-root gate.
#
# PREREG.md §8 and §10. This is where the authority boundary is, so it is worth
# stating what the boundary IS before any code:
#
#     TRUSTED ROOT                    UNTRUSTED CANDIDATE ROOT
#       policy                          flake
#       judge implementation            source
#       policy schema                   candidate config
#                                       candidate workflows
#                                       candidate copy of the gate
#
# The gate reads its policy, its schema and its own implementation from the
# TRUSTED root. It reads the dependency graph, and only the graph, from the
# candidate root. The candidate's copy of the judge is HASHED AND REPORTED --
# it is never executed, sourced, or consulted for a value.
#
# Why a head workflow calling `base/bin/...` is not enough, said once more
# because it is the thing that looks solved and is not: the candidate can edit
# the workflow that does the calling. That is why the two roots are two
# INPUTS to this function rather than one root and a convention.
#
# WHAT THIS DOES NOT CLAIM
#
#   This proves the SEMANTICS of that separation, locally. It does NOT claim
#   that an ordinary workflow inside a personal GitHub repository provides
#   real GitHub-level judge independence -- it does not, and PREREG.md §10
#   said so before this file existed. Real enforcement needs an
#   organization-level required workflow or an external trusted judge, and
#   both are a separate envelope.

# The files that CONSTITUTE the judge. Hashed as a set, so adding a new one to
# the candidate is as visible as editing an existing one.
# An ARRAY, not a word list. A word list has to be left unquoted to expand,
# and an unquoted expansion is one stray glob character away from meaning
# something else -- in the one place where "which files ARE the judge" must not
# be open to interpretation.
NSE_PG_JUDGE_FILES=(
  bin/nse-pg
  lib/pg-common.sh
  lib/pg-facts.sh
  lib/pg-digest.sh
  lib/pg-policy.sh
  lib/pg-gate.sh
)

# ---------------------------------------------------------------------------
# nse_pg_identity_of <root> <relative-path...>
#
# A deterministic identity over a SET of files.
#
# Each line is "<path> <sha256|ABSENT>", sorted by path, and the identity is
# the sha256 of that listing. ABSENT is spelled out rather than skipped: a
# candidate that DELETES the judge must not produce the same identity as one
# that never had it, and a set built by skipping missing files gives exactly
# that.
# ---------------------------------------------------------------------------
nse_pg_identity_of() {
  local root=$1; shift
  local rel listing
  listing=$(
    for rel in "$@"; do
      if [ -f "$root/$rel" ]; then
        printf '%s %s\n' "$rel" "$(sha256sum "$root/$rel" | cut -d' ' -f1)"
      else
        printf '%s ABSENT\n' "$rel"
      fi
    done | LC_ALL=C sort
  )
  printf '%s\n' "$listing" | sha256sum | cut -d' ' -f1
}

# The per-file listing, for a report that can say WHICH file differs rather
# than that something does. Count to detect, name to diagnose.
nse_pg_identity_listing() {
  local root=$1; shift
  local rel
  {
    for rel in "$@"; do
      if [ -f "$root/$rel" ]; then
        printf '%s %s\n' "$rel" "$(sha256sum "$root/$rel" | cut -d' ' -f1)"
      else
        printf '%s ABSENT\n' "$rel"
      fi
    done | LC_ALL=C sort
  } | nse_pg_jq -R -s 'split("\n") | map(select(length > 0) | split(" ")
                        | { path: .[0], sha256: .[1] })'
}

# Workflow files are discovered, not listed: a candidate that ADDS a workflow
# has changed what will run, and a fixed list would not see it.
nse_pg_workflow_files() {
  local root=$1
  if [ -d "$root/.github/workflows" ]; then
    ( cd "$root" && find .github/workflows -type f 2>/dev/null | LC_ALL=C sort )
  fi
}

# ---------------------------------------------------------------------------
# Where a revision came from. Provenance, again, and for the same reason:
# ENFORCED_POLICY_COMMIT=<something> is worth nothing if nothing records
# whether that something was read from git or invented here.
# ---------------------------------------------------------------------------
nse_pg_root_revision() {
  local root=$1 explicit=${2:-}
  if [ -n "$explicit" ]; then
    printf '%s\t%s\n' "$explicit" "OPERATOR_SUPPLIED"; return 0
  fi
  if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse HEAD >/dev/null 2>&1; then
    printf '%s\t%s\n' "$(git -C "$root" rev-parse HEAD)" "GIT_HEAD"; return 0
  fi
  # Not "unknown". The identity of the policy file itself is a real, checkable
  # answer, and it is labelled as what it is rather than borrowed from git.
  if [ -f "$root/nix-source-escrow.toml" ]; then
    printf 'policyfile:%s\t%s\n' \
      "$(sha256sum "$root/nix-source-escrow.toml" | cut -d' ' -f1)" "POLICY_FILE_SHA256"
    return 0
  fi
  printf '%s\t%s\n' "UNKNOWN" "UNKNOWN"
}

# ---------------------------------------------------------------------------
# nse_pg_gate <trusted-root> <candidate-root> <report> [<trusted-rev>] [<candidate-rev>]
# ---------------------------------------------------------------------------
nse_pg_gate() {
  local trusted=$1 candidate=$2 report=$3 trusted_rev_opt=${4:-} candidate_rev_opt=${5:-}
  local work=${report%/*}/gate-work
  rm -rf "$work"; mkdir -p "$work" || nse_pg_checker_error "cannot create $work"

  [ -d "$trusted" ]   || nse_pg_checker_error "no trusted root at $trusted"
  [ -d "$candidate" ] || nse_pg_checker_error "no candidate root at $candidate"

  nse_pg_step "GATE  trusted=$trusted  candidate=$candidate"

  # ---- 1. the ENFORCED policy, from the trusted root and nowhere else -----
  local trev tsrc crev csrc
  IFS=$'\t' read -r trev tsrc < <(nse_pg_root_revision "$trusted" "$trusted_rev_opt")
  IFS=$'\t' read -r crev csrc < <(nse_pg_root_revision "$candidate" "$candidate_rev_opt")

  local trusted_toml=$trusted/nix-source-escrow.toml
  [ -f "$trusted_toml" ] \
    || nse_pg_checker_error "the TRUSTED root has no nix-source-escrow.toml. A gate with no
       enforced policy is not a lenient gate, it is a gate that cannot run.
       Refusing rather than falling back to the candidate's copy -- which is
       precisely the substitution this whole design exists to prevent."
  nse_pg_policy_load "$trusted_toml" "$trev" > "$work/policy-enforced.json"

  # ---- 2. the PROPOSED policy: read, previewed, and NOT applied -----------
  local candidate_toml=$candidate/nix-source-escrow.toml
  local policy_changed=NO proposed_rev=NONE
  if [ -f "$candidate_toml" ]; then
    proposed_rev="policyfile:$(sha256sum "$candidate_toml" | cut -d' ' -f1)"
    if cmp -s "$trusted_toml" "$candidate_toml"; then policy_changed=NO; else policy_changed=YES; fi
    # Loaded so the summary can PREVIEW what it would do. Loading is not
    # applying: nothing below reads a value out of this document to decide
    # anything about this candidate.
    if nse_pg_policy_load "$candidate_toml" "$proposed_rev" > "$work/policy-proposed.json" 2>"$work/proposed.err"; then
      : # a proposed policy that parses
    else
      printf 'null\n' > "$work/policy-proposed.json"
    fi
  else
    policy_changed=YES
    printf 'null\n' > "$work/policy-proposed.json"
  fi
  nse_pg_log "policy: enforced from $trev ($tsrc); proposed $proposed_rev; POLICY_CHANGED=$policy_changed"

  # ---- 3. judge and workflow identity ------------------------------------
  local judge_trusted judge_candidate
  judge_trusted=$(nse_pg_identity_of "$trusted" "${NSE_PG_JUDGE_FILES[@]}")
  judge_candidate=$(nse_pg_identity_of "$candidate" "${NSE_PG_JUDGE_FILES[@]}")

  local -a wf_trusted_files=() wf_candidate_files=()
  mapfile -t wf_trusted_files   < <(nse_pg_workflow_files "$trusted")
  mapfile -t wf_candidate_files < <(nse_pg_workflow_files "$candidate")
  # The UNION of both file lists, so an ADDED workflow moves the identity too.
  # Comparing each root only against its own files would let a candidate add a
  # workflow and keep a matching identity.
  local -a wf_union=()
  mapfile -t wf_union < <(printf '%s\n' "${wf_trusted_files[@]}" "${wf_candidate_files[@]}" \
                          | LC_ALL=C sort -u | sed '/^$/d')
  local wf_trusted_id wf_candidate_id
  if [ "${#wf_union[@]}" -eq 0 ]; then
    wf_trusted_id=NO_WORKFLOWS; wf_candidate_id=NO_WORKFLOWS
  else
    wf_trusted_id=$(nse_pg_identity_of "$trusted" "${wf_union[@]}")
    wf_candidate_id=$(nse_pg_identity_of "$candidate" "${wf_union[@]}")
  fi

  # ---- 4. facts, from the CANDIDATE root ---------------------------------
  local head_facts=$candidate/facts.json base_facts=$trusted/facts.json
  [ -f "$head_facts" ] \
    || nse_pg_checker_error "no facts document at $head_facts. The graph is the one thing
       this gate DOES read from the candidate, and it is not optional."
  [ -f "$base_facts" ] \
    || nse_pg_checker_error "no facts document at $base_facts. Without the base graph there is
       nothing to call 'added', and POLICY_DEPENDENCY_COCHANGE cannot be
       evaluated. An unevaluable guard is not a guard that passes."

  # ---- 5. decisions: TRUSTED policy over CANDIDATE facts ------------------
  nse_pg_decide "$head_facts" "$work/policy-enforced.json" > "$work/decisions.json"

  # The same candidate facts under the PROPOSED policy. Preview only, and used
  # for exactly one thing: telling the reviewer what the proposal WOULD do.
  if nse_pg_jq_test 'type == "object"' "$work/policy-proposed.json"; then
    nse_pg_decide "$head_facts" "$work/policy-proposed.json" > "$work/decisions-preview.json" \
      || printf 'null\n' > "$work/decisions-preview.json"
  else
    printf 'null\n' > "$work/decisions-preview.json"
  fi

  # ---- 6. digests --------------------------------------------------------
  #
  # The BASE facts are decided under the SAME ENFORCED POLICY as the head
  # facts. That is what makes effectiveDecisionDigest a usable comparison:
  # one policy, two graphs, and the question "did the same policy reach a
  # different conclusion?" -- which is precisely the C3 observable.
  #
  # Comparing the raw facts documents alone left effectiveDecisionDigest
  # NOT_COMPUTED on every run, because a facts document has no decisions in it.
  # A digest that is structurally incapable of being computed is not a digest
  # that agrees; it is a lamp that is not wired up.
  nse_pg_decide "$base_facts" "$work/policy-enforced.json" > "$work/decisions-base.json"
  nse_pg_jq -s '.[0] * {decisions: .[1].decisions}' \
    "$base_facts" "$work/decisions-base.json" > "$work/base-with-decisions.json"
  nse_pg_jq -s '.[0] * {decisions: .[1].decisions}' \
    "$head_facts" "$work/decisions.json" > "$work/head-with-decisions.json"
  nse_pg_digests "$work/base-with-decisions.json" > "$work/digests-base.json"
  nse_pg_digests "$work/head-with-decisions.json" > "$work/digests-head.json"
  nse_pg_digest_compare "$work/digests-base.json" "$work/digests-head.json" > "$work/digest-compare.json"

  # ---- 7. findings -------------------------------------------------------
  local judge_listing_t judge_listing_c wf_listing_t wf_listing_c
  judge_listing_t=$(nse_pg_identity_listing "$trusted" "${NSE_PG_JUDGE_FILES[@]}")
  judge_listing_c=$(nse_pg_identity_listing "$candidate" "${NSE_PG_JUDGE_FILES[@]}")
  if [ "${#wf_union[@]}" -eq 0 ]; then
    wf_listing_t='[]'; wf_listing_c='[]'
  else
    wf_listing_t=$(nse_pg_identity_listing "$trusted" "${wf_union[@]}")
    wf_listing_c=$(nse_pg_identity_listing "$candidate" "${wf_union[@]}")
  fi

  nse_pg_jq -n \
    --arg trustedRoot "$trusted" --arg candidateRoot "$candidate" \
    --arg enforcedRev "$trev" --arg enforcedRevSource "$tsrc" \
    --arg candidateRev "$crev" --arg candidateRevSource "$csrc" \
    --arg proposedRev "$proposed_rev" --arg policyChanged "$policy_changed" \
    --arg judgeTrusted "$judge_trusted" --arg judgeCandidate "$judge_candidate" \
    --argjson judgeListingTrusted "$judge_listing_t" \
    --argjson judgeListingCandidate "$judge_listing_c" \
    --arg wfTrusted "$wf_trusted_id" --arg wfCandidate "$wf_candidate_id" \
    --argjson wfListingTrusted "$wf_listing_t" \
    --argjson wfListingCandidate "$wf_listing_c" \
    --slurpfile policy "$work/policy-enforced.json" \
    --slurpfile proposed "$work/policy-proposed.json" \
    --slurpfile decisions "$work/decisions.json" \
    --slurpfile preview "$work/decisions-preview.json" \
    --slurpfile cmp "$work/digest-compare.json" \
    --slurpfile baseFacts "$base_facts" \
    --slurpfile headFacts "$head_facts" \
    '
    ($policy[0]) as $P | ($proposed[0]) as $Q | ($decisions[0]) as $D
    | ($preview[0]) as $PV | ($cmp[0]) as $C
    | ($P.governance) as $G

    # Which dependencies are NEW in this proposal? By CONTENT IDENTITY, not by
    # id: a dependency that keeps its bytes and changes its name is not new,
    # and one that keeps its name and changes its bytes is.
    | ( [ $baseFacts[0].dependencies[] | .contentIdentity.storePath ] ) as $baseKeys
    | ( [ $headFacts[0].dependencies[]
          | select( .contentIdentity.storePath as $k | ($baseKeys | index($k)) == null ) ] ) as $added

    # Is the PROPOSED policy weaker than the ENFORCED one, FOR A DEPENDENCY
    # THIS PROPOSAL ADDS? That conjunction is what PREREG.md §11.E names, and
    # it is deliberately narrow: a policy change alone is not a cochange, and
    # a new dependency alone is not either.
    | ( if $PV == null then []
        else
          [ $added[] | .id as $id
            | ($D.decisions[]  | select(.sourceId == $id)) as $enforced
            | ($PV.decisions[] | select(.sourceId == $id)) as $prop
            | { sourceId: $id,
                enforced: $enforced.effective,
                proposed: $prop.effective }
            | select( (.proposed.coverage  != .enforced.coverage)
                   or (.proposed.retention != .enforced.retention)
                   or (.proposed.admission != .enforced.admission) ) ]
        end ) as $cochanged

    | ( [
        # --- C1: the candidate policy did not govern -----------------------
        ( if $policyChanged == "YES" then
            { id: "POLICY_CHANGED", severity: "INFO",
              detail: "the candidate changes nix-source-escrow.toml. The verdict below was rendered under the policy at \($enforcedRev), which is the BASE. The copy carried by the candidate is PREVIEW ONLY and governed nothing." }
          else empty end ),
        # --- C2: the judge ---------------------------------------------------
        ( if $judgeTrusted != $judgeCandidate then
            { id: "JUDGE_MISMATCH",
              severity: (if $G.judgeOnMismatch == "reject" then "REJECT" else "WARN" end),
              detail: "the judge implementation carried by the candidate differs from the trusted one. TRUSTED_JUDGE_SHA=\($judgeTrusted) CANDIDATE_JUDGE_SHA=\($judgeCandidate). It was hashed and reported; it was never executed. A judge change must land as a base change first, exactly as a policy change must.",
              differingFiles: [ ($judgeListingCandidate[] as $c
                                 | ($judgeListingTrusted[] | select(.path == $c.path)) as $t
                                 | select($t.sha256 != $c.sha256)
                                 | { path: $c.path, trusted: $t.sha256, candidate: $c.sha256 }) ] }
          else empty end ),
        # --- the workflow ----------------------------------------------------
        ( if $wfTrusted != $wfCandidate then
            { id: "WORKFLOW_MISMATCH",
              severity: (if $G.workflowOnMismatch == "reject" then "REJECT" else "WARN" end),
              detail: "the candidate changes the workflow set. TRUSTED_WORKFLOW_IDENTITY=\($wfTrusted) CANDIDATE_WORKFLOW_IDENTITY=\($wfCandidate). NOTE: this is a check of the MODEL. It does not assert that a personal GitHub repository already has an external required workflow -- PREREG.md §10.",
              differingFiles: [ ($wfListingCandidate[] as $c
                                 | ($wfListingTrusted[] | select(.path == $c.path)) as $t
                                 | select($t.sha256 != $c.sha256)
                                 | { path: $c.path, trusted: $t.sha256, candidate: $c.sha256 }) ] }
          else empty end ),
        # --- C3: same bytes, different policy-visible facts -------------------
        ( if $C.dependencyContent == "UNCHANGED" and $C.policyFacts == "CHANGED" then
            { id: "ORIGIN_MOVED", severity: "INFO",
              detail: "DEPENDENCY_CONTENT_UNCHANGED and POLICY_FACTS_CHANGED. The bytes are identical and something a policy selector can read is not. effectiveDecision=\($C.effectiveDecision): the SAME enforced policy was re-run over both graphs, so a changed decision here is the re-evaluation itself and not a different policy.",
              effectiveDecision: $C.effectiveDecision }
          else empty end ),
        # --- §11.E ------------------------------------------------------------
        ( if ($cochanged | length) > 0 then
            { id: "POLICY_DEPENDENCY_COCHANGE",
              severity: (if $G.policyDependencyCochange == "reject" then "REJECT" else "WARN" end),
              detail: "this proposal changes the policy AND adds \($cochanged | length) dependenc(y/ies) whose verdict that change would move. The first version refuses to be clever about such a merge: land the policy change on the base, then bring the dependency in a separate proposal.",
              affected: $cochanged }
          else empty end ),
        # --- policy-level failures --------------------------------------------
        ( if $D.counts.ruleConflicts > 0 then
            { id: "RULE_CONFLICT", severity: "REJECT",
              detail: "\($D.counts.ruleConflicts) axis/axes could not be resolved: rules tie at the same specificity and disagree. This fails closed rather than picking one.",
              affected: [ $D.decisions[] | select([.conflicts[] | select(.kind == "RULE_CONFLICT")] | length > 0) | { sourceId, conflicts } ] }
          else empty end ),
        ( if $D.counts.policyConflicts > 0 then
            { id: "POLICY_CONFLICT", severity: "WARN",
              detail: "\($D.counts.policyConflicts) source annotation(s) asked for a WEAKER value than the trusted base policy allows. An annotation may only strengthen: the base value stands and the attempt is recorded here.",
              affected: [ $D.decisions[] | select([.conflicts[] | select(.kind == "POLICY_CONFLICT")] | length > 0) | { sourceId, conflicts } ] }
          else empty end ),
        ( if $D.counts.quarantined > 0 then
            { id: "QUARANTINED_DEPENDENCY", severity: "REJECT",
              detail: "\($D.counts.quarantined) dependenc(y/ies) are admitted only under quarantine by the enforced policy.",
              affected: [ $D.decisions[] | select(.acceptance == "quarantined") | { sourceId, matchedRuleIds, effective } ] }
          else empty end ),
        ( if $D.counts.undecided > 0 then
            { id: "UNDECIDED_DEPENDENCY", severity: "REJECT",
              detail: "\($D.counts.undecided) dependenc(y/ies) have no effective policy at all. An unresolved policy does not get to be a cautious verdict." }
          else empty end )
      ] ) as $findings

    | { schemaVersion: 1,
        kind: "policy-governed-gate",
        roots: { trusted: $trustedRoot, candidate: $candidateRoot },
        # PREREG.md §8 requires these three, by these names, in the evidence.
        ENFORCED_POLICY_COMMIT: $enforcedRev,
        ENFORCED_POLICY_COMMIT_SOURCE: $enforcedRevSource,
        PROPOSED_POLICY_COMMIT: $proposedRev,
        POLICY_CHANGED: $policyChanged,
        candidateRevision: { value: $candidateRev, source: $candidateRevSource },
        judge: { trustedSha256: $judgeTrusted, candidateSha256: $judgeCandidate,
                 candidateJudgeExecuted: false,
                 files: $judgeListingTrusted },
        workflow: { trustedIdentity: $wfTrusted, candidateIdentity: $wfCandidate },
        digests: $C,
        addedDependencies: [ $added[] | .id ],
        decisions: $D,
        proposedPolicyPreview:
          (if $Q == null then null
           else { revision: $Q.revision,
                  wouldChangeVerdictsFor: $cochanged,
                  note: "PREVIEW ONLY. Loaded so a reviewer can see what the proposal would do. No value from this document decided anything above." }
           end),
        findings: $findings,
        verdict: (if ([ $findings[] | select(.severity == "REJECT") ] | length) > 0
                  then "REJECTED" else "ACCEPTED" end),
        rejectedBy: [ $findings[] | select(.severity == "REJECT") | .id ] }' \
    | nse_pg_write_json "$report"

  nse_pg_gate_summary "$report"
  if nse_pg_jq_test '.verdict == "ACCEPTED"' "$report"; then return 0; fi
  return "$NSE_PG_FAIL"
}

nse_pg_gate_summary() {
  local f=$1
  {
    nse_pg_jq -r '"ENFORCED_POLICY_COMMIT=" + .ENFORCED_POLICY_COMMIT
                    + " (" + .ENFORCED_POLICY_COMMIT_SOURCE + ")",
                  "PROPOSED_POLICY_COMMIT=" + .PROPOSED_POLICY_COMMIT,
                  "POLICY_CHANGED=" + .POLICY_CHANGED,
                  "TRUSTED_JUDGE_SHA=" + .judge.trustedSha256,
                  "CANDIDATE_JUDGE_SHA=" + .judge.candidateSha256,
                  "TRUSTED_WORKFLOW_IDENTITY=" + .workflow.trustedIdentity,
                  "CANDIDATE_WORKFLOW_IDENTITY=" + .workflow.candidateIdentity,
                  "DEPENDENCY_CONTENT=" + .digests.dependencyContent,
                  "POLICY_FACTS=" + .digests.policyFacts,
                  "FLAKE_SOURCE=" + .digests.flakeSource,
                  "DIGEST_SHAPE=" + .digests.shape' "$f"
    nse_pg_jq -r '.findings[] | "FINDING " + .severity + " " + .id' "$f"
    nse_pg_jq -r '"VERDICT=" + .verdict' "$f"
  } >&2
}
