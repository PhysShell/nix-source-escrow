# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is inside a jq program
# handed to nse_pg_jq rather than to `jq`, so shellcheck cannot tell. See the
# same note in lib/pg-qualify.sh.
#
# policy-governed line -- COMMIT 3, annotation qualification.
#
# PREREG.md §3. The claim under test is C4:
#
#     a source policy annotation changes derivation identities but not
#     realised output identities, and causes no rebuild work
#
# and the reason to expect it is not politeness about Nix. A .drv is a
# TEXT-content-addressed store object: its identity is the hash of its own
# text, so adding an attribute to it necessarily moves its store path. But
# Nix's hash-modulo rule resolves a FIXED-OUTPUT input to the content identity
# of its OUTPUT, not to the identity of the .drv that produced it. The change
# therefore stops at the .drv layer.
#
# Three derivations, not two. In the closed line's fixture the annotated
# source's only consumer IS the top-level derivation, so "direct consumer" and
# "top-level" would be one derivation counted twice: six registered observables
# would be four, and the table would look complete while measuring less than it
# says.

NSE_PG_ANN_PAIRS="src mid top"

# nse_pg_out_path <flakeref> <attr>
# The realised output path. Via `nix eval`, which answers identically on both
# document schemas -- this is an identity question, and it should not be routed
# through the document format that the closed line proved differs.
nse_pg_out_path() {
  nse_nix eval --raw "${1}#${2}.outPath"
}

nse_pg_drv_path() {
  nse_nix path-info --derivation "${1}#${2}"
}

# The realised set, exactly as lib/preserve.sh computes it:
#
#     nix-store --query --requisites --include-outputs <top.drv>
#
# It CONTAINS THE .drv FILES. That is not incidental -- it is the arithmetic of
# gap-23 in the closed line, where OBJECTS_REALISED rose by two for one added
# source and was briefly filed as unexplained. One fixed-output source
# contributes its .drv AND its output.
#
# Which is why §3.4 registers count SAME and set DIFFERENT: three .drv
# identities move, three leave the set and three enter it, and the cardinality
# does not budge.
nse_pg_realised_set() {
  nix-store --query --requisites --include-outputs "$1" 2>/dev/null | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# nse_pg_qualify_annotation <flakeref> <report>
# ---------------------------------------------------------------------------
nse_pg_qualify_annotation() {
  local flakeref=$1 report=$2
  local work=${report%/*}/work-annotation
  rm -rf "$work"; mkdir -p "$work" \
    || nse_pg_checker_error "cannot create working directory $work"

  nse_pg_step "QUALIFY ANNOTATION  $flakeref"
  nse_pg_log "nix: $(nse_nix_version)"

  # ---- 1. identities, before anything is built ---------------------------
  local level plain_drv marked_drv plain_out marked_out
  local -a rows=()
  for level in $NSE_PG_ANN_PAIRS; do
    plain_drv=$(nse_pg_drv_path "$flakeref" "ann-plain-$level") \
      || nse_pg_checker_error "cannot resolve derivation for ann-plain-$level"
    marked_drv=$(nse_pg_drv_path "$flakeref" "ann-marked-$level") \
      || nse_pg_checker_error "cannot resolve derivation for ann-marked-$level"
    plain_out=$(nse_pg_out_path "$flakeref" "ann-plain-$level") \
      || nse_pg_checker_error "cannot resolve outPath for ann-plain-$level"
    marked_out=$(nse_pg_out_path "$flakeref" "ann-marked-$level") \
      || nse_pg_checker_error "cannot resolve outPath for ann-marked-$level"
    rows+=("$(nse_pg_jq -n \
      --arg level "$level" --arg pd "$plain_drv" --arg md "$marked_drv" \
      --arg po "$plain_out" --arg mo "$marked_out" \
      '{ level: $level,
         plainDrv: $pd, markedDrv: $md,
         plainOut: $po, markedOut: $mo,
         drvIdentity:    (if $pd == $md then "SAME" else "DIFFERENT" end),
         outputIdentity: (if $po == $mo then "SAME" else "DIFFERENT" end) }')")
    nse_pg_log "$level: drv $( [ "$plain_drv" = "$marked_drv" ] && echo SAME || echo DIFFERENT ), out $( [ "$plain_out" = "$marked_out" ] && echo SAME || echo DIFFERENT )"
  done
  local levels_json; levels_json=$(printf '%s\n' "${rows[@]}" | nse_pg_jq -s '.')

  # ---- 2. is the annotation visible where a matcher would look? ----------
  nse_pg_drv_document "$flakeref" "ann-marked-src" "$work" >/dev/null
  nse_pg_drv_document "$flakeref" "ann-plain-src"  "$work" >/dev/null
  local marked_has plain_has marked_site
  marked_has=$(nse_pg_jq -r "$(nse_pg_jq_prelude)"'
    to_entries[0].value as $d | (nse_pg_has($d; "nseEscrowCoverage") | tostring)' \
    "$work/ann-marked-src.drvs.json")
  marked_site=$(nse_pg_jq -r "$(nse_pg_jq_prelude)"'
    to_entries[0].value as $d | (nse_pg_attr_site($d; "nseEscrowCoverage") // "null")' \
    "$work/ann-marked-src.drvs.json")
  # THE RED CONTROL for the visibility guard, and it is not optional: a probe
  # that answers "visible" for every derivation it is shown is a probe that
  # answers "visible". The unannotated source must come back false on the same
  # reader in the same run.
  plain_has=$(nse_pg_jq -r "$(nse_pg_jq_prelude)"'
    to_entries[0].value as $d | (nse_pg_has($d; "nseEscrowCoverage") | tostring)' \
    "$work/ann-plain-src.drvs.json")

  # ---- 3. rebuild work ---------------------------------------------------
  # Realise the PLAIN chain only. Then ask whether the MARKED chain's outputs
  # are already valid. If they are, there is nothing left for a build to do,
  # by construction -- which is a stronger statement than parsing "these N
  # derivations will be built" out of a human-readable message whose wording
  # differs between the two Nix versions under test.
  nse_pg_log "realising the PLAIN chain"
  local build_log=$work/build-plain.log
  nse_nix build --no-link "${flakeref}#ann-plain-top" >"$build_log" 2>&1 \
    || nse_pg_checker_error "could not realise ann-plain-top: $(tail -c 600 "$build_log")"

  local marked_outs=() valid_before=0 invalid_before=0
  for level in $NSE_PG_ANN_PAIRS; do
    marked_outs+=("$(nse_pg_jq -r --arg l "$level" \
      '.[] | select(.level == $l) | .markedOut' <<<"$levels_json")")
  done
  local p
  for p in "${marked_outs[@]}"; do
    if nse_nix path-info "$p" >/dev/null 2>&1; then
      valid_before=$((valid_before + 1))
    else
      invalid_before=$((invalid_before + 1))
      printf '%s\n' "$p" >> "$work/invalid-before.txt"
    fi
  done
  nse_pg_log "marked chain outputs already valid after building only the plain chain: $valid_before of ${#marked_outs[@]}"

  nse_pg_log "realising the MARKED chain"
  local marked_log=$work/build-marked.log
  local t0 t1
  t0=$(date +%s%N)
  nse_nix build --no-link "${flakeref}#ann-marked-top" >"$marked_log" 2>&1 \
    || nse_pg_checker_error "could not realise ann-marked-top: $(tail -c 600 "$marked_log")"
  t1=$(date +%s%N)
  local marked_build_ms=$(( (t1 - t0) / 1000000 ))

  # ---- 4. the realised sets ----------------------------------------------
  local plain_top_drv marked_top_drv
  plain_top_drv=$(nse_pg_jq -r '.[] | select(.level=="top") | .plainDrv' <<<"$levels_json")
  marked_top_drv=$(nse_pg_jq -r '.[] | select(.level=="top") | .markedDrv' <<<"$levels_json")
  nse_pg_realised_set "$plain_top_drv"  > "$work/realised-plain.txt"
  nse_pg_realised_set "$marked_top_drv" > "$work/realised-marked.txt"
  local n_plain n_marked
  n_plain=$(wc -l < "$work/realised-plain.txt")
  n_marked=$(wc -l < "$work/realised-marked.txt")
  # Expected non-empty by construction: a realised chain has requisites. Zero
  # is a read failure, not a closure with nothing in it.
  [ "$n_plain" -gt 0 ] && [ "$n_marked" -gt 0 ] \
    || nse_pg_checker_error "nix-store --query --requisites returned an EMPTY set for a
       chain that was just realised. That cannot be true, so it is treated as a
       read failure rather than as an empty closure."

  LC_ALL=C comm -23 "$work/realised-plain.txt" "$work/realised-marked.txt" > "$work/only-plain.txt"
  LC_ALL=C comm -13 "$work/realised-plain.txt" "$work/realised-marked.txt" > "$work/only-marked.txt"
  local only_plain only_marked only_plain_drv only_marked_drv
  only_plain=$(wc -l < "$work/only-plain.txt")
  only_marked=$(wc -l < "$work/only-marked.txt")
  only_plain_drv=$(grep -c '\.drv$' "$work/only-plain.txt" || true)
  only_marked_drv=$(grep -c '\.drv$' "$work/only-marked.txt" || true)

  # The same quantity closure.json is hashed over -- the sorted realised set.
  # Named for what it is rather than borrowed from the closed line's tooling:
  # closureSha256 is a hash of a FILE this stage does not produce.
  local sha_plain sha_marked
  sha_plain=$(sha256sum "$work/realised-plain.txt" | cut -d' ' -f1)
  sha_marked=$(sha256sum "$work/realised-marked.txt" | cut -d' ' -f1)

  nse_pg_jq -n \
    --arg nixVersion "$(nse_nix_version)" \
    --arg flakeRef "$flakeref" \
    --argjson levels "$levels_json" \
    --argjson markedHas "$marked_has" \
    --argjson plainHas "$plain_has" \
    --arg markedSite "$marked_site" \
    --argjson validBefore "$valid_before" \
    --argjson invalidBefore "$invalid_before" \
    --argjson outputsChecked "${#marked_outs[@]}" \
    --argjson markedBuildMs "$marked_build_ms" \
    --argjson nPlain "$n_plain" --argjson nMarked "$n_marked" \
    --argjson onlyPlain "$only_plain" --argjson onlyMarked "$only_marked" \
    --argjson onlyPlainDrv "${only_plain_drv:-0}" --argjson onlyMarkedDrv "${only_marked_drv:-0}" \
    --arg shaPlain "$sha_plain" --arg shaMarked "$sha_marked" \
    '{ schemaVersion: 1,
       kind: "policy-governed-annotation-qualification",
       preregSections: ["§3.4", "§3.5", "§3.6"],
       nixVersion: $nixVersion,
       flakeRef: $flakeRef,
       mechanism: "src.overrideAttrs (_: { nseEscrowCoverage = \"required\"; })",
       levels: $levels,
       annotationVisibility: {
         markedSourceCarriesIt: $markedHas,
         attrSite: (if $markedSite == "null" then null else $markedSite end),
         # The red control, in the document rather than only in a test name.
         # Without it, "visible" is what this probe says about everything.
         redControlUnannotatedSource: $plainHas,
         qualified: ($markedHas and ($plainHas | not))
       },
       rebuildWork: {
         markedOutputsAlreadyValidAfterPlainBuildOnly: $validBefore,
         markedOutputsChecked: $outputsChecked,
         markedOutputsNotValid: $invalidBefore,
         markedChainBuildMilliseconds: $markedBuildMs,
         verdict: (if $invalidBefore == 0 then "NO_REBUILD_WORK" else "REBUILD_WORK" end)
       },
       realisedSet: {
         plainCount: $nPlain,
         markedCount: $nMarked,
         countIdentity: (if $nPlain == $nMarked then "SAME" else "DIFFERENT" end),
         setIdentity: (if ($onlyPlain + $onlyMarked) == 0 then "SAME" else "DIFFERENT" end),
         onlyInPlain: $onlyPlain,
         onlyInMarked: $onlyMarked,
         onlyInPlainDrv: $onlyPlainDrv,
         onlyInMarkedDrv: $onlyMarkedDrv,
         # The gap-23 arithmetic, asserted rather than done after the fact:
         # three .drv identities move, three leave and three arrive, and
         # EVERY member of the symmetric difference is a .drv. A non-.drv in
         # there is a moved OUTPUT, which is C4 refuted.
         symmetricDifferenceIsAllDrv:
           (($onlyPlain == $onlyPlainDrv) and ($onlyMarked == $onlyMarkedDrv)),
         plainSha256: $shaPlain,
         markedSha256: $shaMarked,
         # PREREG.md §3.5, registered in advance: this MOVING is expected
         # churn, not a regression. It is the same quantity closure.json is
         # hashed over, named for what this stage actually computed.
         realisedSetShaIdentity: (if $shaPlain == $shaMarked then "SAME" else "DIFFERENT" end)
       },
       # PREREG.md §3.6. A changed .drv is not a refutation. A changed OUTPUT
       # is, and so is any build step that had to run.
       c4: (
         ($levels | all(.drvIdentity == "DIFFERENT")) as $drvsMoved
         | ($levels | all(.outputIdentity == "SAME")) as $outputsHeld
         | { allThreeDrvsMoved: $drvsMoved,
             allThreeOutputsHeld: $outputsHeld,
             noRebuildWork: ($invalidBefore == 0),
             annotationVisible: ($markedHas and ($plainHas | not)),
             verdict: (if ($drvsMoved and $outputsHeld and ($invalidBefore == 0)
                           and $markedHas and ($plainHas | not))
                       then "C4_AS_PREREGISTERED" else "C4_DEVIATION" end) }) }' \
    | nse_pg_write_json "$report"

  nse_pg_annotation_summary "$report"
}

nse_pg_annotation_summary() {
  local f=$1
  {
    printf 'NIX_VERSION=%s\n' "$(nse_pg_jq -r '.nixVersion' "$f")"
    nse_pg_jq -r '.levels[] | "LEVEL_" + (.level|ascii_upcase)
                  + "  drv=" + .drvIdentity + "  output=" + .outputIdentity' "$f"
    nse_pg_jq -r '"ANNOTATION_VISIBLE=" + (.annotationVisibility.markedSourceCarriesIt|tostring)
                  + " at " + (.annotationVisibility.attrSite // "NOWHERE"),
                  "ANNOTATION_RED_CONTROL_UNANNOTATED=" + (.annotationVisibility.redControlUnannotatedSource|tostring),
                  "REBUILD_WORK=" + .rebuildWork.verdict,
                  "OBJECTS_REALISED_COUNT=" + .realisedSet.countIdentity
                    + " (" + (.realisedSet.plainCount|tostring) + " vs " + (.realisedSet.markedCount|tostring) + ")",
                  "OBJECTS_REALISED_SET=" + .realisedSet.setIdentity
                    + " (only-plain " + (.realisedSet.onlyInPlain|tostring)
                    + ", only-marked " + (.realisedSet.onlyInMarked|tostring)
                    + ", all .drv: " + (.realisedSet.symmetricDifferenceIsAllDrv|tostring) + ")",
                  "REALISED_SET_SHA256=" + .realisedSet.realisedSetShaIdentity + " (PREREG §3.5: expected churn)",
                  "C4=" + .c4.verdict' "$f"
  } >&2
}
