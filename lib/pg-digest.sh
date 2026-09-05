# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is a jq program handed
# to nse_pg_jq. See the note in lib/pg-qualify.sh.
#
# policy-governed line -- COMMIT 4, typed digests.
#
# PREREG.md §12. FOUR digests, not one, and the reason is the whole design:
#
#     Hashing discovery.json answers every question with "something changed",
#     which is the same as answering none of them.
#
# discovery.json carries volatile, non-identity data. A README-only change
# would move a single digest over it, and the only honest reading of that
# movement is "166 external dependencies may have changed" -- which is false,
# unhelpful, and exactly the report that trains a reviewer to ignore the tool.
#
# So each digest answers ONE question, and the interesting results are the
# DISAGREEMENTS between them:
#
#   origin moved, content identical
#       dependencyContentDigest  SAME       policyFactsDigest  DIFFERENT
#   README-only change
#       dependencyContentDigest  SAME       policyFactsDigest  SAME
#       flakeSourceDigest        DIFFERENT
#
# Two things are deliberately absent from the content digest and it is worth
# saying why in the code that computes it, not only in the pre-registration:
#
#   drvPath      a policy annotation LEGITIMATELY changes the .drv, and C4 is
#                the measurement that says so. A content digest that moves when
#                a source is annotated reports the annotation as a supply-chain
#                change.
#   lockNodeId   "systems" and "systems_2" are names in a graph, assigned by
#                resolution order. Two graphs holding identical bytes can name
#                them differently, and a content identity that depends on a
#                name is not a content identity.

# ---------------------------------------------------------------------------
# The PROJECTIONS. What is hashed, as a value you can look at.
#
# These are exposed, and the digest is defined as "sha256 of the canonical
# rendering of this projection", because a digest whose input nobody can print
# is a number that can only be trusted. When two digests disagree, the answer
# to "about what?" has to be obtainable.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # a jq program, consumed by the functions below
NSE_PG_JQ_DIGEST='
# The required set. requiredByPlan is a DISCOVERY FACT -- whether the object is
# in the realised closure of the build plan -- and not a policy verdict. Policy
# decides what must be PRESERVED; this decides what the build actually used.
def nse_pg_required: [ .dependencies[] | select(.requiredByPlan == true) ];

# dependencyContentDigest: the identity of the required dependency BYTES.
#
# A fixed-output derivation and a flake input are identified differently
# because they ARE identified differently -- the first by an expected hash the
# fetcher must reproduce, the second by a NAR hash recorded in the lock. Both
# carry their class, so a future collision between the two namespaces cannot
# quietly merge two entries into one.
def nse_pg_dep_content_projection:
  [ nse_pg_required[]
    | if .class == "fod" then
        { class: "fod",
          storePath:        .contentIdentity.storePath,
          expectedHash:     .contentIdentity.expectedHash,
          expectedHashAlgo: .contentIdentity.expectedHashAlgo,
          hashMode:         .contentIdentity.hashMode }
      elif .class == "flake-input" then
        { class: "flake-input",
          storePath: .contentIdentity.storePath,
          narHash:   .contentIdentity.narHash }
      else
        # An unrecognised class is a READ FAILURE. Not skipped, not hashed as
        # an empty object: a dependency this code does not understand must not
        # be able to vanish from the identity of the set it belongs to.
        error("dependency class \(.class // "MISSING") is not one this digest understands. A dependency that cannot be identified is not a dependency with no identity.")
      end ]
  | sort;

# policyFactsDigest: EXACTLY what a matcher selector can read.
#
# Kept in step with the selector list in lib/pg-policy.sh by construction: a
# selector reading a fact that is not in this projection would be a selector
# whose input can change without the digest moving, and the origin-moved
# observable would go quiet for it.
def nse_pg_policy_facts_projection:
  [ .dependencies[]
    | { contentIdentity: ( if .class == "fod"
                           then { storePath: .contentIdentity.storePath,
                                  expectedHash: .contentIdentity.expectedHash,
                                  expectedHashAlgo: .contentIdentity.expectedHashAlgo,
                                  hashMode: .contentIdentity.hashMode }
                           else { storePath: .contentIdentity.storePath,
                                  narHash: .contentIdentity.narHash } end ),
        class:      .class,
        kind:       .kind,
        # The VALUE and its PROVENANCE both. A fact that moves from
        # DERIVATION_ATTR to URL_FALLBACK while keeping its value is a
        # different fact for policy purposes: one is stated, the other is
        # inferred, and PREREG.md §7.3 makes rules behave differently on an
        # UNKNOWN. A digest that ignored provenance would let that transition
        # happen silently.
        originHost: .originHost,
        owner:      .owner,
        repo:       .repo,
        aliasPaths: (.aliasPaths // [] | sort),
        discoveryStatus: .discoveryStatus } ]
  | sort;

# flakeSourceDigest: the identity of the PROJECT source, on its own.
#
# Separate so that a README-only change is reportable as a README-only change.
def nse_pg_flake_source_projection:
  { storePath: (.flakeSource.storePath), narHash: (.flakeSource.narHash) };

# effectiveDecisionDigest: what the trusted judge concluded, and under what.
#
# The trusted policy revision is IN the hash. Two runs that reach the same
# verdicts under different policies are not the same result, and a digest that
# could not tell them apart would make a policy change invisible in exactly the
# document whose job is to record which policy was enforced.
def nse_pg_decision_projection:
  [ .decisions[]
    | { sourceId: .sourceId,
        matchedRuleIds: (.matchedRuleIds // [] | sort),
        effective: { coverage:  .effective.coverage,
                     retention: .effective.retention,
                     admission: .effective.admission },
        trustedPolicyRevision: .trustedPolicyRevision } ]
  | sort;
'

nse_pg_digest_prelude() { printf '%s\n' "$NSE_PG_JQ_DIGEST"; }

# nse_pg_project <facts.json> <projection-name>
nse_pg_project() {
  local doc=$1 proj=$2
  nse_pg_jq -S -c "$(nse_pg_digest_prelude) $proj" "$doc"
}

# nse_pg_digest_of <facts.json> <projection-name>
#
# sha256 over the canonical rendering of the projection. Canonical means jq -S,
# compact, one trailing newline: two documents differing only in key order or
# whitespace must hash the same, or every digest here reports churn instead of
# change and the four-digest design is defeated at the bottom.
nse_pg_digest_of() {
  local doc=$1 proj=$2 projected
  projected=$(nse_pg_project "$doc" "$proj") || return 1
  printf '%s\n' "$projected" | sha256sum | cut -d' ' -f1
}

# All four, as one document.
nse_pg_digests() {
  local doc=$1
  local dep facts src dec
  dep=$(nse_pg_digest_of "$doc" 'nse_pg_dep_content_projection')   || return 1
  facts=$(nse_pg_digest_of "$doc" 'nse_pg_policy_facts_projection') || return 1
  src=$(nse_pg_digest_of "$doc" 'nse_pg_flake_source_projection')   || return 1
  # A facts document has no decisions yet. That is ABSENT, and absent is
  # spelled null -- not the sha256 of an empty array, which is a real-looking
  # digest that two unrelated documents would agree on.
  if nse_pg_jq_test 'has("decisions") and (.decisions | type) == "array"' "$doc"; then
    dec=$(nse_pg_digest_of "$doc" 'nse_pg_decision_projection') || return 1
  else
    dec=""
  fi
  nse_pg_jq -n --arg dep "$dep" --arg facts "$facts" --arg src "$src" --arg dec "$dec" \
    --argjson nDeps "$(nse_pg_jq '.dependencies | length' "$doc")" \
    --argjson nRequired "$(nse_pg_jq '[.dependencies[] | select(.requiredByPlan == true)] | length' "$doc")" \
    '{ dependencyContentDigest: $dep,
       policyFactsDigest:       $facts,
       flakeSourceDigest:       $src,
       effectiveDecisionDigest: (if $dec == "" then null else $dec end),
       scope: { dependenciesDiscovered: $nDeps,
                dependenciesRequiredByPlan: $nRequired,
                dependencyContentDigestCovers: "requiredByPlan == true",
                policyFactsDigestCovers: "every discovered dependency, because the matcher evaluates every one of them" } }'
}

# The comparison that the whole design exists to make: WHICH digests moved.
#
#   nse_pg_digest_compare <base-digests.json> <head-digests.json>
#
# Reported as named transitions, never as "changed". "Something is different"
# is the single-digest answer this line replaced.
nse_pg_digest_compare() {
  local base=$1 head=$2
  nse_pg_jq -n --slurpfile b "$base" --slurpfile h "$head" \
    '($b[0]) as $B | ($h[0]) as $H
     | { dependencyContent: (if $B.dependencyContentDigest == $H.dependencyContentDigest
                             then "UNCHANGED" else "CHANGED" end),
         policyFacts:       (if $B.policyFactsDigest == $H.policyFactsDigest
                             then "UNCHANGED" else "CHANGED" end),
         flakeSource:       (if $B.flakeSourceDigest == $H.flakeSourceDigest
                             then "UNCHANGED" else "CHANGED" end),
         effectiveDecision: (if $B.effectiveDecisionDigest == null or $H.effectiveDecisionDigest == null
                             then "NOT_COMPUTED"
                             elif $B.effectiveDecisionDigest == $H.effectiveDecisionDigest
                             then "UNCHANGED" else "CHANGED" end) }
     | . + { # The named shapes. A reviewer should not have to reconstruct
             # what a combination means from four words.
             shape:
               (if   .dependencyContent == "UNCHANGED" and .policyFacts == "CHANGED"
                then "ORIGIN_MOVED_OR_FACTS_CHANGED"
                elif .dependencyContent == "UNCHANGED" and .policyFacts == "UNCHANGED"
                     and .flakeSource == "CHANGED"
                then "PROJECT_SOURCE_ONLY"
                elif .dependencyContent == "CHANGED"
                then "DEPENDENCY_BYTES_CHANGED"
                else "NO_RELEVANT_CHANGE" end) }'
}
