# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 is disabled for this FILE, not silenced at ten call sites. Every
# single-quoted $ below is inside a jq program, and jq programs are passed to
# nse_pg_jq rather than to `jq` -- so shellcheck, which knows to leave a
# single-quoted argument to `jq` alone, cannot tell. The wrapper is not
# optional: it is what turns a jq that writes to stderr into a CHECKER_ERROR
# instead of into an empty string somebody reads as a zero (PREREG.md §17.1).
#
# policy-governed line -- COMMIT 2, facts qualification.
#
# PREREG.md §4 and §5. Two questions, both of which the nixpkgs source can
# suggest and only a run can answer:
#
#   §4  Which of owner / repo / rev / tag / githubBase / stripRoot / extension
#       are actually visible in the derivation document, on EACH Nix version,
#       and with what provenance?
#
#   §5  What does a bare `escrow = true` passed to the public fetcher do:
#       REJECTED, DROPPED, or SURVIVED?
#
# The nixpkgs source is not evidence for either. The closed line established
# that expensively: the same tool, on the same flake, saw 165 fixed-output
# sources on one Nix version and 0 on the other, because the DOCUMENT shape
# differed and not the graph. A fact reader validated against one shape has a
# 50% chance of being a fact reader.

# The probes the qualification fixture exposes, and what each is for.
NSE_PG_QUAL_TARGETS="qual-plain qual-sentinel qual-direct-attr"

# nse_pg_target_drv <flakeref> <attr> <workdir>
#   stdout: the derivation path, if it evaluates
#   file:   <workdir>/<attr>.eval.log holds stderr either way
# Returns non-zero when evaluation FAILS, which for qual-direct-attr is a
# result and not an accident.
nse_pg_target_drv() {
  local flakeref=$1 attr=$2 work=$3
  nse_nix path-info --derivation "${flakeref}#${attr}" 2>"$work/$attr.eval.log"
}

# nse_pg_drv_document <flakeref> <attr> <workdir>
#   Writes <workdir>/<attr>.drvs.json (normalised: bare object names as keys)
#   Echoes the document SCHEMA, which is itself a recorded observable.
nse_pg_drv_document() {
  local flakeref=$1 attr=$2 work=$3
  nse_nix derivation show "${flakeref}#${attr}" > "$work/$attr.raw.json" \
    2>"$work/$attr.drvshow.log" \
    || nse_pg_checker_error "nix derivation show failed for ${flakeref}#${attr}: $(
         tr '\n' ' ' < "$work/$attr.drvshow.log" | head -c 400)"
  local schema; schema=$(nse_drv_schema "$work/$attr.raw.json")
  case $schema in
    envelope|flat-map) : ;;
    *) nse_pg_checker_error "unrecognised 'nix derivation show' schema from $(nse_nix_version)
       for ${flakeref}#${attr}. Neither a {version, derivations} envelope nor a
       flat map of *.drv objects. An unreadable document is not an empty one:
       refusing to report facts about it. Document: $work/$attr.raw.json" ;;
  esac
  nse_drv_map "$work/$attr.raw.json" > "$work/$attr.drvs.json" \
    || nse_pg_checker_error "cannot normalise $work/$attr.raw.json"
  # Expected non-empty by construction: `nix derivation show` of ONE installable
  # holds at least that installable's derivation. Zero is a read failure.
  local n; n=$(nse_pg_jq -r 'length' "$work/$attr.drvs.json")
  [ "$n" -gt 0 ] \
    || nse_pg_checker_error "parsed 0 derivations from a $schema document Nix produced
       for ${flakeref}#${attr}. That cannot be true of an installable that
       resolves, so it is a read failure, not an empty document."
  printf '%s\n' "$schema"
}

# ---------------------------------------------------------------------------
# §5 -- classify a bare `escrow = true`.
#
# THE SHAPE OF THIS FUNCTION IS THE POINT. DROPPED is an absence, and an
# absence is only evidence when the instrument that reports it has been shown,
# on the same run and on the same kind of document, capable of reporting a
# presence. So the sentinel is checked FIRST, and a sentinel that is missing
# yields CHECKER_ERROR -- never DROPPED.
#
# Without that ordering, "the attribute is not there" and "the detector cannot
# see attributes" produce the same output, and PREREG.md §5 says in advance
# that such a result may not be scored as a success.
# ---------------------------------------------------------------------------
nse_pg_classify_direct_attr() {
  local work=$1 eval_ok=$2 eval_log=$3

  # Outcome 1: it did not evaluate. That is a real, distinguishable result.
  if [ "$eval_ok" != yes ]; then
    nse_pg_jq -n --rawfile err "$eval_log" \
      '{ attribute: "escrow",
         outcome: "DIRECT_ATTR_REJECTED",
         detectorQualified: null,
         sentinel: null,
         foundAtSite: null,
         evalError: ($err | .[0:1200]),
         attrKeys: null }'
    return 0
  fi

  # The detector, qualified before it is believed.
  local sentinel_found sentinel_site
  sentinel_found=$(nse_pg_jq -r "$(nse_pg_jq_prelude)"'
    to_entries[0].value as $d | (nse_pg_has($d; "nsePgSentinel") | tostring)' \
    "$work/qual-sentinel.drvs.json")
  sentinel_site=$(nse_pg_jq -r "$(nse_pg_jq_prelude)"'
    to_entries[0].value as $d | (nse_pg_attr_site($d; "nsePgSentinel") // "null")' \
    "$work/qual-sentinel.drvs.json")

  local escrow_found escrow_site keys
  escrow_found=$(nse_pg_jq -r "$(nse_pg_jq_prelude)"'
    to_entries[0].value as $d | (nse_pg_has($d; "escrow") | tostring)' \
    "$work/qual-direct-attr.drvs.json")
  escrow_site=$(nse_pg_jq -r "$(nse_pg_jq_prelude)"'
    to_entries[0].value as $d | (nse_pg_attr_site($d; "escrow") // "null")' \
    "$work/qual-direct-attr.drvs.json")
  keys=$(nse_pg_jq -c "$(nse_pg_jq_prelude)"'
    to_entries[0].value as $d | nse_pg_attr_keys($d)' \
    "$work/qual-direct-attr.drvs.json")

  local outcome
  if [ "$escrow_found" = true ]; then
    # A presence needs no sentinel: the detector demonstrably just found
    # something. Recorded anyway, because a run that reports SURVIVED with a
    # missing sentinel is telling us something about the sentinel.
    outcome=DIRECT_ATTR_SURVIVED
  elif [ "$sentinel_found" = true ]; then
    outcome=DIRECT_ATTR_DROPPED
  else
    # Absence, from an instrument that has not shown it can see a presence.
    # This is NOT DROPPED. PREREG.md §5.
    outcome=CHECKER_ERROR
  fi

  nse_pg_jq -n \
    --arg outcome "$outcome" \
    --argjson sentinelFound "$sentinel_found" \
    --arg sentinelSite "$sentinel_site" \
    --arg foundAtSite "$escrow_site" \
    --argjson keys "$keys" \
    '{ attribute: "escrow",
       outcome: $outcome,
       detectorQualified: $sentinelFound,
       sentinel: { attribute: "nsePgSentinel",
                   found: $sentinelFound,
                   attrSite: (if $sentinelSite == "null" then null else $sentinelSite end) },
       foundAtSite: (if $foundAtSite == "null" then null else $foundAtSite end),
       evalError: null,
       attrKeys: $keys,
       note: (if $outcome == "CHECKER_ERROR"
              then "The escrow attribute is absent AND the sentinel attribute is absent. An instrument that cannot find an attribute it was told is there has not measured an absence. This is not DROPPED."
              elif $outcome == "DIRECT_ATTR_DROPPED"
              then "Absent from the derivation document, reported by a detector that found the sentinel in the same run. PREREG.md §5: not promoted to an API, and not scored as a success."
              else "Present in the derivation document. PREREG.md §5: a measurement of this fetcher chain at this pin, NOT a public API." end) }'
}

# ---------------------------------------------------------------------------
# The whole of commit 2, as one document.
#
#   nse_pg_qualify_facts <flakeref> <outfile>
# ---------------------------------------------------------------------------
nse_pg_qualify_facts() {
  # `report`, never `out`: see nse_pg_jq in lib/pg-common.sh and u14.
  local flakeref=$1 report=$2
  # The working documents are KEPT, beside the result, and uploaded with it.
  # A qualification report whose raw derivation documents were deleted is a
  # claim about documents nobody can re-read; every number in this line's
  # history that turned out to be wrong was re-derived from a kept document.
  local work=${report%/*}/work
  rm -rf "$work"; mkdir -p "$work" \
    || nse_pg_checker_error "cannot create working directory $work"

  nse_pg_step "QUALIFY FACTS  $flakeref"
  nse_pg_log "nix: $(nse_nix_version)"

  local t schema eval_ok
  local -a probe_docs=()
  NSE_PG_DIRECT_EVAL_OK=no
  NSE_PG_DIRECT_EVAL_LOG=/dev/null
  for t in $NSE_PG_QUAL_TARGETS; do
    eval_ok=yes
    local drv=""
    if drv=$(nse_pg_target_drv "$flakeref" "$t" "$work"); then
      schema=$(nse_pg_drv_document "$flakeref" "$t" "$work")
      nse_pg_log "$t: evaluates, document schema $schema"
      local facts
      facts=$(nse_pg_facts_of "$work/$t.drvs.json" "$drv") \
        || nse_pg_checker_error "the derivation Nix resolved for ${flakeref}#${t} ($drv)
       is not in the document Nix produced for it. Two Nix invocations
       disagreeing about one installable is a read failure, not a fact."
      probe_docs+=("$(nse_pg_jq -n --arg target "$t" --arg schema "$schema" \
        --arg drvPath "$drv" --argjson facts "$facts" \
        '{ target: $target, evaluates: true, drvSchema: $schema,
           drvPath: $drvPath, evalError: null } + $facts')")
    else
      eval_ok=no
      nse_pg_log "$t: DOES NOT EVALUATE (recorded as a result, not an error)"
      probe_docs+=("$(nse_pg_jq -n --arg target "$t" --rawfile err "$work/$t.eval.log" \
        '{ target: $target, evaluates: false, drvSchema: null, drvPath: null,
           drv: null, name: null, facts: null, attrKeys: null,
           evalError: ($err | .[0:1200]) }')")
    fi
    if [ "$t" = qual-direct-attr ]; then
      NSE_PG_DIRECT_EVAL_OK=$eval_ok
      NSE_PG_DIRECT_EVAL_LOG=$work/$t.eval.log
    fi
  done

  local direct
  direct=$(nse_pg_classify_direct_attr "$work" \
             "${NSE_PG_DIRECT_EVAL_OK:-no}" "${NSE_PG_DIRECT_EVAL_LOG:-/dev/null}")

  # PREREG.md §3.3 -- the Nix-VALUE surface, kept separate from the
  # derivation-document surface above. They are two different questions and
  # answering one with the other is how "the nixpkgs source says so" becomes
  # "the tool can see it". This section decides whether a wrapper is justified;
  # the section above decides what the matcher may select on.
  local value_facts="null"
  if nse_nix eval --json "${flakeref}#pgValueFacts.x86_64-linux" \
       > "$work/value-facts.json" 2>"$work/value-facts.log"; then
    value_facts=$(cat "$work/value-facts.json")
  else
    nse_pg_warn "could not read pgValueFacts: $(tr '\n' ' ' < "$work/value-facts.log" | head -c 300)"
  fi

  local probes_json
  probes_json=$(printf '%s\n' "${probe_docs[@]}" | nse_pg_jq -s '.')

  nse_pg_jq -n \
    --arg nixVersion "$(nse_nix_version)" \
    --arg flakeRef "$flakeref" \
    --arg pin "d2f67949798825fe853f7c5d0492b8bf016d3f88" \
    --argjson probes "$probes_json" \
    --argjson directAttr "$direct" \
    --argjson valueFacts "$value_facts" \
    '{ schemaVersion: 1,
       kind: "policy-governed-facts-qualification",
       preregSections: ["§3.3", "§4", "§5"],
       nixVersion: $nixVersion,
       flakeRef: $flakeRef,
       nixpkgsPin: $pin,
       probes: $probes,
       directAttr: $directAttr,
       nixValueVisibility: $valueFacts,
       # The §4 answer, reduced to the one line a policy author needs: which
       # selectors this Nix version can actually support for a fixed-output
       # source. A rule whose selector reads a fact recorded UNKNOWN does not
       # match, and records SELECTOR_FACT_UNKNOWN (PREREG.md §7.3). It does not
       # match permissively and it does not match conservatively.
       selectorSupport: (
         ($probes | map(select(.target == "qual-plain")) | .[0].facts) as $f
         | if $f == null then null
           else ($f | with_entries({ key: .key, value: .value.source })) end) }' \
    | nse_pg_write_json "$report"

  nse_pg_qualify_summary "$report"
}

nse_pg_qualify_summary() {
  local f=$1
  {
    printf 'NIX_VERSION=%s\n' "$(nse_pg_jq -r '.nixVersion' "$f")"
    printf 'DRV_SCHEMA=%s\n' \
      "$(nse_pg_jq -r '[.probes[] | select(.drvSchema != null) | .drvSchema] | unique | join(",")' "$f")"
    # NAMED, not counted. EXPERIMENT-PROTOCOL.md §1: count to detect, name to
    # diagnose. "3 of 8 facts visible" has supported three different stories in
    # this repository's history; a list of which three has never supported more
    # than one.
    nse_pg_jq -r '.selectorSupport // {} | to_entries[]
                  | "FACT_" + (.key | ascii_upcase) + "=" + .value' "$f"
    printf 'DIRECT_ATTR=%s\n' "$(nse_pg_jq -r '.directAttr.outcome' "$f")"
    printf 'DIRECT_ATTR_DETECTOR_QUALIFIED=%s\n' \
      "$(nse_pg_jq -r '.directAttr.detectorQualified | tostring' "$f")"
  } >&2
}
