# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is a jq program.
#
# policy-governed line -- the adversarial corpus, GENERATED FROM A SEED.
#
# PREREG.md §11.1 is the reason this is a generator and not five directories
# somebody typed:
#
#   SEED_PROVENANCE = SYNTHETIC   the corpus is a MECHANISM TEST, indexed as
#                                 one, and is NOT evidence for C1/C2/C3
#   SEED_PROVENANCE = RECORDED    the seed came off a real graph, and the
#                                 corpus is evidence
#
# A hand-written facts document is the "fixture the world never produces" shape
# from EXPERIMENT-PROTOCOL.md §1. The way out is not to write a better one by
# hand; it is to make the corpus a FUNCTION of a seed, so the identical
# mutations can be applied to a document that a real Nix produced.
#
# The checked-in fixtures are generated from the synthetic seed so the corpus
# runs with no Nix and no network. CI generates a second copy from a RECORDED
# facts document and gates that too. Same code, two seeds, and the report says
# which one it was.
#
# WHAT IS AND IS NOT INHERITED FROM THE SEED. The dependencies are the seed's.
# The adversarial dependency each mutation ADDS is necessarily constructed --
# there is no real graph containing the dependency an attacker has not added
# yet -- and it is labelled as constructed in SEED.json. A recorded seed makes
# the GRAPH real; it does not make the attack real, and this line does not
# claim it does.

# ---------------------------------------------------------------------------
# The base policy is DERIVED FROM THE SEED, and that is a correctness
# requirement rather than a convenience.
#
# Every fixture is gated base-against-base as a control, and that control must
# be ACCEPTED. A fixed policy written against the 3-dependency synthetic seed
# quarantines half of a real 150-dependency graph, every control goes red, and
# the whole corpus stops proving anything -- which is exactly the defect the
# first version of this corpus had.
#
# So: one rule per origin host the seed actually contains, one contentIdentity
# rule per dependency whose origin is UNKNOWN (a real project writes exactly
# these by hand: "these two bootstrap sources have no origin and are accepted
# by name"), and a DEFAULT of quarantine. A source with neither a named origin
# nor an exemption by identity is admitted only under quarantine -- which is
# what the mutations then walk into.
# ---------------------------------------------------------------------------
nse_pg_corpus_policy() {
  local seed=$1 extra=${2:-}
  {
    cat <<'HEADER'
# TRUSTED BASE POLICY -- DERIVED FROM THE SEED by lib/pg-corpus.sh.
#
# Not hand-written, because it has to ACCEPT ITS OWN BASE STATE on whatever
# seed it was derived from: every fixture is gated base-against-base first and
# that control must be ACCEPTED, or the corpus proves nothing about any
# mutation.
#
# The default is QUARANTINE. A source with neither a named origin nor an
# exemption by content identity is admitted only under quarantine.
schemaVersion = 1

[defaults]
coverage = "auto"
retention = "while-referenced"
admission = "quarantine"

[governance]
judgeOnMismatch = "reject"
workflowOnMismatch = "reject"
policyDependencyCochange = "reject"
HEADER
    nse_pg_jq -r '
      def slug: gsub("[^A-Za-z0-9]"; "-");
      ( [ .dependencies[] | select(.originHost.source != "UNKNOWN") | .originHost.value ]
        | unique ) as $hosts
      | ( [ .dependencies[] | select(.originHost.source == "UNKNOWN")
            | .contentIdentity.storePath ] | unique ) as $unknown
      | ( [ $hosts[]
            | "",
              "[[rule]]",
              "id = \"r-host-\(. | slug)\"",
              "originHost = \"\(.)\"",
              "admission = \"normal\"",
              (if . == "github.com" then "coverage = \"required\"" else "coverage = \"auto\"" end) ]
          + [ $unknown[]
            | "",
              "[[rule]]",
              "# No origin was observed for this source. A real project writes",
              "# exactly this rule by hand: accepted BY IDENTITY, named, and",
              "# reviewable -- rather than by widening the default.",
              "id = \"r-identity-\(. | sub("^.*/"; "") | slug)\"",
              "contentIdentity = \"\(.)\"",
              "admission = \"normal\"" ] )
      | .[]' "$seed"
    [ -n "$extra" ] && printf '%s\n' "$extra"
    :
  }
}

# The stand-in judge and workflow. They exist to be HASHED, so their content
# matters only in that the hostile variants differ from the trusted ones.
nse_pg_corpus_judge()      { printf '#!/usr/bin/env bash\n# A stand-in judge, so the fixture has one to hash.\nexec true\n'; }
nse_pg_corpus_judge_evil() { printf '#!/usr/bin/env bash\n# What a hostile candidate ships instead.\necho PASS\nexit 0\n'; }
nse_pg_corpus_workflow() {
  printf 'name: escrow gate\non: [push]\njobs:\n  gate:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: ./bin/nse-pg gate --trusted-root base --candidate-root .\n'
}
nse_pg_corpus_workflow_evil() {
  printf 'name: escrow gate\non: [push]\njobs:\n  gate:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "gate skipped"\n'
}

# The per-fixture READMEs are GENERATED too, so they cannot drift away from the
# fixture they describe -- which is what happens to every hand-maintained
# description of a generated thing.
nse_pg_corpus_readme() {
  local dir=$1 which=$2
  mkdir -p "$dir"
  case $which in
    A) cat > "$dir/README.md" <<'EOF'
# A. policy self-exemption  (C1)

GENERATED by lib/pg-corpus.sh. See ../SEED.json for the seed and its
provenance; do not edit by hand.

The candidate adds a dependency from a host the base policy admits only under
quarantine, and in the same proposal writes the rule that would exempt exactly
that host.

Required trace:

    POLICY_CHANGED = YES
    ENFORCED_POLICY_COMMIT = <base>
    rejectedBy includes QUARANTINED_DEPENDENCY

The exemption is REAL: the gate report shows, from the candidate's own policy,
that this dependency WOULD have been admitted normally with coverage `ignore`.
It simply is not the policy that decided this proposal.

CONTROL: base gated against base is ACCEPTED. Without that, this fixture would
be red whether or not the base policy governed anything.
EOF
       ;;
    B) cat > "$dir/README.md" <<'EOF'
# B. judge replacement  (C2)

GENERATED by lib/pg-corpus.sh. See ../SEED.json; do not edit by hand.

The candidate leaves the policy and the graph alone and replaces its own copy
of the judge with `echo PASS; exit 0`.

Required trace:

    JUDGE_MISMATCH
    TRUSTED_JUDGE_SHA = <expected>
    rejectedBy == [JUDGE_MISMATCH]     -- and nothing else

The replacement judge is never executed. It is hashed and reported.

Note what happens WITHOUT the boundary: the head workflow calls the head judge,
which prints PASS, and every other check in this corpus is green because none
of them runs.

CONTROL: base against base is ACCEPTED, so this red comes from the judge swap
and from nothing else -- rejectedBy has exactly one entry.
EOF
       ;;
    C) cat > "$dir/README.md" <<'EOF'
# C. workflow replacement

GENERATED by lib/pg-corpus.sh. See ../SEED.json; do not edit by hand.

The candidate edits the workflow so the gate never runs.

Required trace:

    WORKFLOW_MISMATCH
    TRUSTED_WORKFLOW_IDENTITY = <expected fixture identity>
    rejectedBy == [WORKFLOW_MISMATCH]

THIS FIXTURE TESTS THE MODEL AND THE HARNESS. It does not assert, and must not
be read as asserting, that a personal GitHub repository already has an external
required workflow. PREREG.md §10: real enforcement needs an organization-level
required workflow or an external trusted judge, and both belong to a separate
envelope.

CONTROL: base against base is ACCEPTED.
EOF
       ;;
    D) cat > "$dir/README.md" <<'EOF'
# D. same content, new origin  (C3)

GENERATED by lib/pg-corpus.sh. See ../SEED.json; do not edit by hand.

Byte-identical content: same `expectedHash`, same `storePath`, same `hashMode`.
The ORIGIN moves to a host the trusted policy does not name.

Required trace:

    DEPENDENCY_CONTENT_UNCHANGED
    POLICY_FACTS_CHANGED
    ORIGIN_MOVED
    rejectedBy == [QUARANTINED_DEPENDENCY]

Policy evaluation RE-RAN, observably: the dependency lost the rule that used to
cover it, fell through to the default, and `effectiveDecisionDigest` moved while
`dependencyContentDigest` did not.

This is what makes C3 concrete. A tool that keyed its verdict on the content
hash would see nothing here at all -- and would be right that the bytes are the
same, and wrong about everything that matters.

CONTROL: base against base is ACCEPTED.
EOF
       ;;
    E) cat > "$dir/README.md" <<'EOF'
# E. policy and dependency in one proposal

GENERATED by lib/pg-corpus.sh. See ../SEED.json; do not edit by hand.

One proposal that BOTH weakens the policy AND adds the dependency the weakening
applies to. The dependency itself is unobjectionable: under the base policy
alone it is accepted. The weakening is narrow and plausible -- it exempts
exactly one vendor.

Required trace:

    POLICY_DEPENDENCY_COCHANGE
    rejectedBy == [POLICY_DEPENDENCY_COCHANGE]   -- and nothing else

The single-entry rejectedBy is the point. Nothing else about this proposal is
wrong, so if the cochange guard were deleted this specimen would go green --
which is what makes it a specimen.

The first version refuses to be clever here. It does not weigh whether the
exemption is reasonable. The policy change lands on the base first; the
dependency arrives in a later proposal, governed by a policy that was already
reviewed on its own.

CONTROL: base against base is ACCEPTED.
EOF
       ;;
  esac
}

# nse_pg_corpus_root <dir> <policy-file> <facts-file> <judge-fn> <workflow-fn>
nse_pg_corpus_root() {
  local dir=$1 policy=$2 facts=$3 judge=$4 workflow=$5
  mkdir -p "$dir/bin" "$dir/lib" "$dir/.github/workflows"
  cp "$policy" "$dir/nix-source-escrow.toml"
  cp "$facts"  "$dir/facts.json"
  "$judge" > "$dir/bin/nse-pg"; chmod 0755 "$dir/bin/nse-pg"
  local libname
  for libname in pg-common pg-facts pg-digest pg-policy pg-gate; do
    printf '# fixture stand-in for lib/%s.sh\n' "$libname" > "$dir/lib/$libname.sh"
  done
  "$workflow" > "$dir/.github/workflows/gate.yml"
}

# The constructed adversarial dependency. jq, so it is one definition rather
# than five near-copies.
# shellcheck disable=SC2034
NSE_PG_JQ_CORPUS='
def nse_pg_unknown_fact: { value: null, source: "UNKNOWN", attrKey: null, attrSite: null };
def nse_pg_new_dep($name; $host; $kind; $owner):
  { id: ("fod:/nix/store/" + ($name + "0000000000000000000000000000000")[0:32] + "-" + $name),
    class: "fod",
    kind: $kind,
    requiredByPlan: true,
    requiredByPlanReason: "CONSTRUCTED_ADVERSARIAL_DEPENDENCY",
    drvPath: ("/nix/store/" + ($name + "dddddddddddddddddddddddddddddddd")[0:32] + "-" + $name + ".drv"),
    contentIdentity: {
      storePath: ("/nix/store/" + ($name + "0000000000000000000000000000000")[0:32] + "-" + $name),
      expectedHash: ("sha256-" + (($name * 8) + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")[0:42] + "="),
      expectedHashAlgo: "sha256",
      hashMode: "nar" },
    originHost: { value: $host, source: "URL_FALLBACK", attrKey: "url", attrSite: "url" },
    owner: (if $owner == null then nse_pg_unknown_fact
            else { value: $owner, source: "DERIVATION_ATTR", attrKey: "owner", attrSite: "structuredAttrs" } end),
    repo:  nse_pg_unknown_fact,
    rev:   nse_pg_unknown_fact,
    tag:   nse_pg_unknown_fact,
    aliasPaths: [],
    discoveryStatus: "COVERED",
    annotation: null };
'

# ---------------------------------------------------------------------------
# nse_pg_corpus_generate <seed-facts.json> <outdir>
# ---------------------------------------------------------------------------
nse_pg_corpus_generate() {
  local seed=$1 out=$2
  local prov; prov=$(nse_pg_jq -r '.seedProvenance // "UNDECLARED"' "$seed")
  case $prov in
    SYNTHETIC|RECORDED) : ;;
    *) nse_pg_checker_error "the seed at $seed does not declare its provenance.
       PREREG.md §11.1 makes the corpus mean two different things depending on
       that field, so a seed that does not state it cannot be used at all." ;;
  esac

  local tmp; tmp=$out/.gen
  rm -rf "$out"; mkdir -p "$tmp"

  # Which dependency fixture D moves. One that HAS an observed origin -- moving
  # an already-unknown one would change nothing a selector can read.
  local moved_id
  moved_id=$(nse_pg_jq -r '
    [ .dependencies[] | select(.originHost.source != "UNKNOWN")
      | select(.class == "fod") ] | .[0].id // ""' "$seed")
  [ -n "$moved_id" ] || moved_id=$(nse_pg_jq -r '
    [ .dependencies[] | select(.originHost.source != "UNKNOWN") ] | .[0].id // ""' "$seed")
  [ -n "$moved_id" ] \
    || nse_pg_checker_error "the seed has no dependency with an observed origin host, so
       the origin-moved fixture cannot be constructed from it. A corpus that
       silently skipped that fixture would report four controls as five."

  # A host the seed does NOT contain, so the mutations land outside the derived
  # policy rather than inside it.
  local adversary_host=vendor.example.invalid
  local mirror_host=mirror.example.invalid

  cp "$seed" "$tmp/base-facts.json"
  nse_pg_corpus_policy "$tmp/base-facts.json" > "$tmp/base.toml"

  # --- A: policy self-exemption ------------------------------------------
  nse_pg_jq "$NSE_PG_JQ_CORPUS"'
    .dependencies += [ nse_pg_new_dep("vendorpkg"; "'"$adversary_host"'"; "fetchurl"; "some-vendor") ]' \
    "$seed" > "$tmp/a-head-facts.json"
  { cat "$tmp/base.toml"
    printf '\n[[rule]]\n# The exemption the candidate wrote for itself.\nid = "r-vendor-exempt"\noriginHost = "%s"\nadmission = "normal"\ncoverage = "ignore"\n' "$adversary_host"
  } > "$tmp/a-head.toml"
  nse_pg_corpus_readme "$out/policy-self-exemption" A
  nse_pg_corpus_root "$out/policy-self-exemption/base" "$tmp/base.toml" "$tmp/base-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow
  nse_pg_corpus_root "$out/policy-self-exemption/head" "$tmp/a-head.toml" "$tmp/a-head-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow

  # --- B: judge replacement ----------------------------------------------
  nse_pg_corpus_readme "$out/judge-replacement" B
  nse_pg_corpus_root "$out/judge-replacement/base" "$tmp/base.toml" "$tmp/base-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow
  nse_pg_corpus_root "$out/judge-replacement/head" "$tmp/base.toml" "$tmp/base-facts.json" \
    nse_pg_corpus_judge_evil nse_pg_corpus_workflow

  # --- C: workflow replacement -------------------------------------------
  nse_pg_corpus_readme "$out/workflow-replacement" C
  nse_pg_corpus_root "$out/workflow-replacement/base" "$tmp/base.toml" "$tmp/base-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow
  nse_pg_corpus_root "$out/workflow-replacement/head" "$tmp/base.toml" "$tmp/base-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow_evil

  # --- D: same content, new origin ----------------------------------------
  # The content identity is NOT touched. Only the origin, and the kind, so the
  # source stops matching the rule that used to cover it.
  nse_pg_jq --arg id "$moved_id" --arg host "$mirror_host" '
    .dependencies |= map(
      if .id == $id
      then .originHost = { value: $host, source: "URL_FALLBACK", attrKey: "url", attrSite: "url" }
           | .kind = "fetchurl"
      else . end)' "$seed" > "$tmp/d-head-facts.json"
  nse_pg_corpus_readme "$out/origin-moved" D
  nse_pg_corpus_root "$out/origin-moved/base" "$tmp/base.toml" "$tmp/base-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow
  nse_pg_corpus_root "$out/origin-moved/head" "$tmp/base.toml" "$tmp/d-head-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow

  # --- E: policy and dependency in one proposal ---------------------------
  # The added dependency is ACCEPTABLE on its own -- a named host, admitted
  # normally -- so the ONLY thing wrong with this proposal is the conjunction.
  # That is what makes it a specimen: delete the cochange guard and it goes
  # green.
  local known_host
  # Prefer github.com when the seed has it: the derived policy gives that host
  # `coverage = "required"`, so the weakening this fixture proposes is a starker
  # required -> ignore rather than auto -> ignore. Any named host works; this
  # one makes the report easier to read.
  known_host=$(nse_pg_jq -r '[ .dependencies[] | select(.originHost.source != "UNKNOWN")
                               | .originHost.value ] | unique
                             | (map(select(. == "github.com")) + .) | .[0]' "$seed")
  nse_pg_jq "$NSE_PG_JQ_CORPUS"'
    .dependencies += [ nse_pg_new_dep("newlib"; "'"$known_host"'"; "fetchzip-like"; "some-vendor") ]' \
    "$seed" > "$tmp/e-head-facts.json"
  { cat "$tmp/base.toml"
    printf '\n[[rule]]\n# Narrow, plausible, and arriving in the same change as the\n# dependency it exempts.\nid = "r-vendor-ignore"\noriginHost = "%s"\nowner = "some-vendor"\ncoverage = "ignore"\n' "$known_host"
  } > "$tmp/e-head.toml"
  nse_pg_corpus_readme "$out/policy-dependency-cochange" E
  nse_pg_corpus_root "$out/policy-dependency-cochange/base" "$tmp/base.toml" "$tmp/base-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow
  nse_pg_corpus_root "$out/policy-dependency-cochange/head" "$tmp/e-head.toml" "$tmp/e-head-facts.json" \
    nse_pg_corpus_judge nse_pg_corpus_workflow

  # The provenance record. Without it a reader cannot tell a mechanism test
  # from evidence, and PREREG.md §11.1 makes that the whole difference.
  nse_pg_jq -n \
    --arg prov "$prov" --arg seedPath "$seed" \
    --arg seedSha "$(sha256sum "$seed" | cut -d' ' -f1)" \
    --argjson deps "$(nse_pg_jq '.dependencies | length' "$seed")" \
    --arg movedId "$moved_id" --arg adversaryHost "$adversary_host" \
    --arg mirrorHost "$mirror_host" --arg knownHost "$known_host" \
    '{ seedProvenance: $prov,
       seedPath: $seedPath,
       seedSha256: $seedSha,
       seedDependencies: $deps,
       movedDependency: $movedId,
       constructedHosts: { adversary: $adversaryHost, mirror: $mirrorHost, known: $knownHost },
       meaning: (if $prov == "RECORDED"
                 then "The GRAPH is a document a real Nix produced. The corpus is evidence for C1/C2/C3."
                 else "The graph is hand-authored. PREREG.md §11.1: this corpus is a MECHANISM TEST, indexed as one, and is NOT evidence for C1/C2/C3." end),
       caveat: "The adversarial dependency each mutation ADDS is constructed in every case. A recorded seed makes the graph real; it does not make the attack real, and this line does not claim it does." }' \
    | nse_pg_write_json "$out/SEED.json"

  rm -rf "$tmp"
  nse_pg_jq -r '"CORPUS_SEED_PROVENANCE=" + .seedProvenance,
                "CORPUS_SEED_DEPENDENCIES=" + (.seedDependencies | tostring),
                "CORPUS_SEED_SHA256=" + .seedSha256' "$out/SEED.json" >&2
}
