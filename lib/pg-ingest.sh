# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is a jq program handed
# to nse_pg_jq.
#
# policy-governed line -- COMMIT 8, part 1: FACTS FROM A REAL GRAPH.
#
# This is the join that stops the adversarial corpus from standing on a
# hand-written document forever. PREREG.md §11.1 permits a SYNTHETIC seed and
# says exactly what it is worth: a mechanism test, indexed as one, and never
# evidence for C1/C2/C3. This file is how a seed becomes RECORDED.
#
# Two readers, joined, and neither of them re-implemented:
#
#   the closed line discover.sh    the graph, the coverage classification, the
#                                  hash algorithm, the IFD probe
#   this line pg-facts.sh          owner / repo / rev / tag / originHost, each
#                                  with its provenance
#
# lib/discover.sh is NOT modified. It belongs to a closed experiment and is
# reused here as an instrument -- the way a second study reuses a calibrated
# instrument from the first -- and its own tests keep passing untouched.

# ---------------------------------------------------------------------------
# nse_pg_facts_join <discovery.json> <drv-facts.json> <required-file>
#                   <required-mode> <nix-version> <drv-schema> <installable>
#
# A SEPARATE FUNCTION, taking files, so the join can be exercised without a
# Nix, a store or a network. The Nix-dependent half of this file cannot run
# outside CI; this half is where every mapping DECISION lives, and a mapping
# that can only be tested in CI is a mapping nobody re-tests.
# ---------------------------------------------------------------------------
nse_pg_facts_join() {
  local discovery=$1 drvfacts=$2 required_file=$3 required_mode=$4
  local nix_version=$5 schema=$6 installable=$7
  nse_pg_jq -n \
    --slurpfile disc "$discovery" \
    --slurpfile drvfacts "$drvfacts" \
    --rawfile required "$required_file" \
    --arg requiredMode "$required_mode" \
    --arg nixVersion "$nix_version" \
    --arg schema "$schema" \
    --arg installable "$installable" \
    '
    def unknownFact: { value: null, source: "UNKNOWN", attrKey: null, attrSite: null };
    def lockFact($v; $k):
      if $v == null then unknownFact
      else { value: $v, source: "LOCK_ATTR", attrKey: $k, attrSite: "flake.lock" } end;

    ($disc[0]) as $D | ($drvfacts[0]) as $A
    | ($required | split("\n") | map(select(length > 0))) as $req
    | ($req | INDEX(.)) as $reqIdx
    | (if $requiredMode == "NOT_OBSERVED" then null else true end) as $observable

    # ---- flake inputs ----------------------------------------------------
    # requiredByPlan is TRUE for these and the REASON is recorded rather than
    # asserted: the plan cannot be EVALUATED without them, which is a different
    # kind of necessity from being in a realised closure, and is labelled as a
    # different one.
    | [ $D.flakeInputs[]
        | { id: ("flake-input:" + (.storePath // .name)),
            class: "flake-input",
            kind: "flake-input",
            requiredByPlan: true,
            requiredByPlanReason: "FLAKE_EVALUATION_INPUT",
            drvPath: null,
            lockNodeId: .lockNodeId,
            contentIdentity: { storePath: .storePath, narHash: .narHash },
            originHost: lockFact(.originHost; "type"),
            owner: lockFact(.locked.owner; "owner"),
            repo:  lockFact(.locked.repo;  "repo"),
            rev:   lockFact(.rev; "rev"),
            tag:   lockFact(.locked.ref; "ref"),
            aliasPaths: (.aliasPaths // []),
            discoveryStatus: .discovery.status,
            annotation: null } ] as $inputs

    # ---- fixed-output sources -------------------------------------------
    | [ $D.sources[]
        | . as $s
        | (($s.drvPath // "") | sub("^.*/"; "")) as $drvKey
        | ($A[$drvKey] // null) as $entry
        | (if $entry == null then null else $entry.facts end) as $f
        | { id: ("fod:" + ($s.storePath // (($s.drvPath // "?") + "!" + $s.outputName))),
            class: "fod",
            kind: $s.kind,
            # THREE answers, and the third is spelled out rather than folded
            # into the second. `auto` coverage means "preserve it if the plan
            # used it", so a requiredByPlan this run could not observe must not
            # arrive as `false` -- that is a silent exemption granted by an
            # instrument rather than by policy. A null here makes mustPreserve
            # null, and the gate rejects that.
            requiredByPlan:
              (if $observable == null then null
               else ($reqIdx[$s.drvPath] != null) end),
            requiredByPlanReason: $requiredMode,
            drvPath: $s.drvPath,
            contentIdentity: { storePath: $s.storePath,
                               expectedHash: $s.expectedHash,
                               expectedHashAlgo: $s.expectedHashAlgo,
                               hashMode: $s.hashMode },
            # The ATTRIBUTE facts, from the reader in lib/pg-facts.sh, with
            # their provenance. A derivation the attribute reader has no entry
            # for yields UNKNOWN facts -- not absent keys, and never facts
            # borrowed from a neighbour.
            originHost: (if $f == null
                         then ( (($s.origin.hosts) // []) as $h
                                | if ($h | length) == 1
                                  then { value: $h[0], source: "URL_FALLBACK",
                                         attrKey: "url", attrSite: "url" }
                                  else unknownFact end )
                         else $f.originHost end),
            owner: (if $f == null then unknownFact else $f.owner end),
            repo:  (if $f == null then unknownFact else $f.repo  end),
            rev:   (if $f == null then unknownFact else $f.rev   end),
            tag:   (if $f == null then unknownFact else $f.tag   end),
            aliasPaths: [],
            discoveryStatus: $s.discovery.status,
            # The annotation, read out of the derivation the same way every
            # other attribute is: an nse-prefixed key, and nothing else. The
            # VALUE is read too -- an annotation whose value this reader cannot
            # place on an axis is left for the matcher to reject rather than
            # silently downgraded here.
            annotation:
              ( (if $entry == null then [] else $entry.attrKeys end) as $keys
              | if ($keys | index("nseEscrowCoverage")) == null then null
                else { coverage: (if $entry == null then null
                                  else $entry.annotationCoverage end) } end ) } ] as $sources

    | { schemaVersion: 1,
        kind: "policy-governed-facts",
        seedProvenance: "RECORDED",
        installable: $installable,
        nixVersion: $nixVersion,
        derivationDocumentSchema: $schema,
        requiredByPlanObservedVia: $requiredMode,
        flakeSource: { storePath: $D.flakeSourcePath,
                       # Recorded null, not omitted. The root narHash is not in
                       # the discovery document, and a digest input that is
                       # absent must be VISIBLY absent rather than quietly
                       # missing from the projection.
                       narHash: null },
        dependencies: ($inputs + $sources),
        counts: { dependencies: (($inputs | length) + ($sources | length)),
                  flakeInputs: ($inputs | length),
                  fixedOutputSources: ($sources | length),
                  requiredByPlan: ([ ($inputs + $sources)[]
                                     | select(.requiredByPlan == true) ] | length),
                  requiredByPlanUnobserved: ([ ($inputs + $sources)[]
                                     | select(.requiredByPlan == null) ] | length),
                  annotated: ([ $sources[] | select(.annotation != null) ] | length) } }'
}

# ---------------------------------------------------------------------------
# nse_pg_facts_build <installable> <report> [<requisites-file>]
#
# The Nix-dependent half. Runs only where there is a Nix and a network.
# ---------------------------------------------------------------------------
nse_pg_facts_build() {
  local installable=$1 report=$2 requisites=${3:-}
  local work=${report%/*}/facts-work
  rm -rf "$work"; mkdir -p "$work" || nse_pg_checker_error "cannot create $work"

  nse_pg_step "FACTS  $installable"
  nse_pg_log "nix: $(nse_nix_version)"

  # ---- 1. the closed line does the discovery ------------------------------
  local escrow_dir=$work/discovery-escrow
  mkdir -p "$escrow_dir"
  NSE_DIR=$escrow_dir NSE_INSTALLABLE=$installable \
    "$NSE_ROOT/bin/nix-source-escrow" discover "$installable" >"$work/discover.log" 2>&1 \
    || nse_pg_checker_error "discovery failed for $installable. Tail: $(tail -c 800 "$work/discover.log")"
  local discovery=$escrow_dir/discovery.json
  [ -s "$discovery" ] || nse_pg_checker_error "discovery produced no document at $discovery"

  # ---- 2. the derivation document, for the ATTRIBUTE facts ----------------
  nse_nix derivation show -r "$installable" > "$work/drvs-raw.json" 2>"$work/drvshow.log" \
    || nse_pg_checker_error "nix derivation show -r failed: $(tail -c 400 "$work/drvshow.log")"
  local schema; schema=$(nse_drv_schema "$work/drvs-raw.json")
  case $schema in
    envelope|flat-map) : ;;
    *) nse_pg_checker_error "unrecognised derivation document schema from $(nse_nix_version).
       An unreadable document is not an empty one." ;;
  esac
  nse_drv_map "$work/drvs-raw.json" > "$work/drvs.json" \
    || nse_pg_checker_error "cannot normalise $work/drvs-raw.json"

  nse_pg_jq "$(nse_pg_jq_prelude)"'
    to_entries
    | map({ key: .key,
            value: { facts: nse_pg_github_facts(.value),
                     attrKeys: nse_pg_attr_keys(.value),
                     annotationCoverage: (nse_pg_attr(.value; "nseEscrowCoverage")) } })
    | from_entries' "$work/drvs.json" > "$work/drv-facts.json"

  # ---- 3. requiredByPlan -------------------------------------------------
  local required_mode required_file=$work/required.txt
  : > "$required_file"
  if [ -n "$requisites" ] && [ -s "$requisites" ]; then
    LC_ALL=C sort -u "$requisites" > "$required_file"
    required_mode=REALISED_CLOSURE
  else
    local top_drv=""
    if top_drv=$(nse_nix path-info --derivation "$installable" 2>/dev/null); then
      if nix-store --query --requisites "$top_drv" 2>/dev/null \
           | LC_ALL=C sort -u > "$required_file" && [ -s "$required_file" ]; then
        required_mode=DERIVATION_CLOSURE
      else
        : > "$required_file"; required_mode=NOT_OBSERVED
      fi
    else
      required_mode=NOT_OBSERVED
    fi
  fi
  nse_pg_log "requiredByPlan observed via: $required_mode ($(wc -l < "$required_file") paths)"

  # ---- 4. the join --------------------------------------------------------
  nse_pg_facts_join "$discovery" "$work/drv-facts.json" "$required_file" \
                    "$required_mode" "$(nse_nix_version)" "$schema" "$installable" \
    | nse_pg_write_json "$report"

  nse_pg_facts_summary "$report"
}

nse_pg_facts_summary() {
  nse_pg_jq -r '"FACTS_DEPENDENCIES=" + (.counts.dependencies | tostring),
                "  flakeInputs=" + (.counts.flakeInputs | tostring)
                + " fixedOutputSources=" + (.counts.fixedOutputSources | tostring),
                "  requiredByPlan=" + (.counts.requiredByPlan | tostring)
                + " unobserved=" + (.counts.requiredByPlanUnobserved | tostring),
                "REQUIRED_BY_PLAN_VIA=" + .requiredByPlanObservedVia,
                "SEED_PROVENANCE=" + .seedProvenance,
                "ANNOTATED_SOURCES=" + (.counts.annotated | tostring)' "$1" >&2
}
