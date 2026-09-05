# shellcheck shell=bash
# PRESERVE: put everything the accepted build needs into a store you control,
# using stock Nix primitives only (nix flake archive / nix copy / a binary
# cache). No custom storage protocol.
#
# The destination is a URL, not a directory. `file://./escrow/cache` is the
# default and the demo backend; an Attic, S3 or Artifactory Nix repository is
# a first-class target and needs no code here, only --escrow-store.

nse_preserve() {
  local work=$NSE_DIR/work
  local staging=${NSE_STAGING:-$work/staging}
  local disc=$NSE_DIR/discovery.json
  [ -f "$disc" ] || nse_die "no discovery.json; run 'nix-source-escrow discover' first"

  mkdir -p "$staging" "$work"
  if nse_url_is_file "$NSE_STORE_URL"; then mkdir -p "$(nse_url_file_path "$NSE_STORE_URL")"; fi
  local flakeref; flakeref=$(nse_flakeref_of "$NSE_INSTALLABLE")

  nse_step "PRESERVE $NSE_INSTALLABLE -> $NSE_STORE_URL (guarantee: $NSE_GUARANTEE)"

  if [ "${NSE_FRESH_STAGING:-0}" = 1 ]; then
    nse_log "wiping staging store (--fresh-staging)"
    chmod -R u+w "$staging" 2>/dev/null || :
    rm -rf "$staging"; mkdir -p "$staging"
  fi

  # ---- 1. flake input material via the stock mechanism ---------------------
  nse_log "nix flake archive -> escrow"
  nse_nix flake archive --json --to "$NSE_STORE_URL" "$flakeref" \
    > "$work/flake-archive-preserve.json" \
    || nse_die "nix flake archive --to '$NSE_STORE_URL' failed"

  # ---- 2. realise the build in a *separate, controlled* store --------------
  # Building into a fresh store (rather than trusting the developer's
  # /nix/store) is what makes the escrow provably self-sufficient: whatever
  # the build needed had to be fetched here, so it is here to be copied.
  nse_log "realising build plan into staging store: $staging"
  NIX_CONFIG="experimental-features = nix-command flakes
warn-dirty = false
build-users-group =
require-drop-supplementary-groups = false" \
    nix build --store "$staging" "$NSE_INSTALLABLE" --no-link --print-out-paths \
    > "$work/staging-out-paths.txt" \
    || nse_die "staging build failed; the escrow would be incomplete, refusing to continue"

  local top_drv; top_drv=$(jq -r '.topLevelDerivation' "$disc")

  # ---- 3. compute the exact set to preserve --------------------------------
  # Build closure (derivations + the outputs actually realised) plus the flake
  # input paths, which are not part of the derivation closure.
  #
  # `--requisites --include-outputs` in the staging store returns exactly the
  # paths that are *valid* there -- Nix only follows an output edge for an
  # output it actually has. That single query therefore answers both questions
  # this step used to ask a separate `nix path-info` per path for: what is in
  # staging, and what the plan really realised. On an 874-path fixture that was
  # 874 process startups; on a 30k-path closure it is a lunch break.
  nse_log "computing preservation set"
  nix-store --store "$staging" --query --requisites --include-outputs "$top_drv" \
    | LC_ALL=C sort -u > "$work/staging-requisites.txt" \
    || nse_die "cannot compute requisites of $top_drv in staging store"
  jq -r '.flakeInputs[].storePath, .flakeSourcePath' "$disc" \
    | LC_ALL=C sort -u > "$work/flake-paths.txt"

  LC_ALL=C sort -u "$work/staging-requisites.txt" "$work/flake-paths.txt" \
    > "$work/preserve-set.txt"

  local n_set; n_set=$(wc -l < "$work/preserve-set.txt")
  nse_log "preservation set: $n_set store paths"

  # ---- 4. split by destination --------------------------------------------
  # ESCROW_REPLAY escrows the whole realised closure: the acceptance test then
  # runs with the escrow as the only substituter.
  #
  # SOURCE_ORIGIN_INDEPENDENCE escrows only the objects that have an origin to
  # lose, and the prebuilt tier comes from an *approved binary cache* rather
  # than from whatever this machine happened to build. See nse_binary_replica.
  jq -r '.sources[] | select(.storePath != null) | .storePath' "$disc" \
    | LC_ALL=C sort -u > "$work/discovered-sources.txt"
  LC_ALL=C comm -12 "$work/discovered-sources.txt" "$work/staging-requisites.txt" \
    > "$work/sources-required.txt"

  : > "$work/replica-set.txt"
  : > "$work/not-provided-set.txt"

  case $NSE_GUARANTEE in
    escrow-replay)
      cp "$work/preserve-set.txt" "$work/escrow-set.txt" ;;
    source-origin-independence)
      LC_ALL=C sort -u "$work/sources-required.txt" "$work/flake-paths.txt" \
        > "$work/escrow-set.txt"
      nse_binary_replica "$work" ;;
    *) nse_die "unknown guarantee '$NSE_GUARANTEE'" ;;
  esac

  nse_copy_set "$work/escrow-set.txt" "$NSE_STORE_URL" "escrow" "$staging" "$work"

  if [ "$NSE_GUARANTEE" = source-origin-independence ]; then
    # Written through a URL carrying the compression parameter: a file:// binary
    # cache with no `compression` defaults to xz, which is a very slow way to
    # store prebuilt binaries nobody intends to archive.
    local replica_store=$NSE_REPLICA_URL
    if nse_url_is_file "$NSE_REPLICA_URL"; then
      mkdir -p "$(nse_url_file_path "$NSE_REPLICA_URL")"
      if [ "$NSE_REPLICA_URL" = "${NSE_REPLICA_URL%%\?*}" ]; then
        replica_store="$NSE_REPLICA_URL?compression=${NSE_COMPRESSION:-zstd}"
      fi
    fi
    nse_tier_materialise "$work" "$NSE_BINARY_TIER" "$replica_store" "$NSE_REPLICA_URL"
    # not-provided is recomputed from what ARRIVED, never from what was claimed.
    LC_ALL=C comm -23 "$work/preserve-set.txt" \
      <(LC_ALL=C sort -u "$work/escrow-set.txt" "$work/replica-set.txt") \
      > "$work/not-provided-set.txt"
    nse_log "binary tier: $(wc -l < "$work/replica-set.txt") materialised, $(wc -l < "$work/not-provided-set.txt") provided to nobody (the test instantiates or rebuilds those)"
  fi

  jq -n \
    --arg guarantee "$NSE_GUARANTEE" \
    --rawfile all         "$work/preserve-set.txt" \
    --rawfile escrowed    "$work/escrow-set.txt" \
    --rawfile replica     "$work/replica-set.txt" \
    --rawfile notProvided "$work/not-provided-set.txt" \
    'def lines($s): ($s | split("\n") | map(select(length>0)) | sort);
     {schemaVersion:3, guarantee:$guarantee,
      paths: lines($all), escrowPaths: lines($escrowed),
      replicaPaths: lines($replica),
      # Realised, but deliberately handed to nobody: the acceptance test has to
      # instantiate or rebuild these itself. Empty under ESCROW_REPLAY.
      notProvidedPaths: lines($notProvided)}' \
    | nse_json_canonical | nse_write_file "$NSE_DIR/closure.json"

  nse_manifest
}

# PROBE: what does the approved binary tier say it has?
#
# Probing and materialising are two different observations and are kept apart,
# because conflating them is how this stage lied twice. v1 filled the replica
# from the STAGING store, so an object this machine built was served as though
# the cache had it. v2 read a cache signature as proof of substitution, which
# is not a law of Nix. v3 asked the tier properly and then believed the answer
# without checking it -- and the answer was wrong, because `nix path-info
# --json` reports an absent path as `"path": null` and the parser counted keys.
#
# So this function only ASKS. nse_tier_materialise finds out what is true.
nse_binary_replica() {
  local work=$1

  LC_ALL=C comm -23 "$work/preserve-set.txt" "$work/escrow-set.txt" \
    > "$work/non-source-set.txt"

  # Derivations are asked of nobody: the acceptance test evaluates the flake
  # and instantiates them itself. Asking a binary cache for a .drv is a
  # category error.
  grep -v '\.drv$' "$work/non-source-set.txt" > "$work/tier-candidates.txt" || :

  nse_log "binary tier: asking $NSE_BINARY_TIER about $(wc -l < "$work/tier-candidates.txt") prebuilt objects"
  nse_observe_present "$NSE_BINARY_TIER" \
    "$work/tier-candidates.txt" "$work/tier-present.txt" \
    "what the approved binary tier claims to hold"
  nse_log "binary tier: claims to hold $(wc -l < "$work/tier-present.txt") of them"
  return 0
}

# MATERIALISE: find out which of those objects the tier will actually hand over.
#
# "The tier says it has X" and "X arrived" are different facts, and the gap
# between them is recorded rather than smoothed over. A copy that fails is
# classified, never swallowed:
#
#   the tier now says it does not have it   -> a revised answer. The object is
#                                              provided to nobody, and the
#                                              acceptance build must produce it
#   anything else (transport, auth, 404 on
#   a path still claimed, corruption)       -> BINARY_TIER_ERROR, hard failure
#
# Turning every copy failure into "not provided, rebuild it" would quietly
# convert an outage, an expired credential or a corrupt narinfo into a
# statistic. That is how a proof tool becomes a marketing department.
nse_tier_materialise() {
  local work=$1 from=$2 to_write=$3 to_read=$4
  cp "$work/tier-present.txt" "$work/tier-requested.txt"
  : > "$work/tier-revised-absent.txt"

  local n_req; n_req=$(wc -l < "$work/tier-requested.txt")
  [ "$n_req" -gt 0 ] || { : > "$work/replica-set.txt"; return 0; }
  nse_log "replica: materialising $n_req objects from the approved tier $from -> $to_write"

  if ! nse_nix_batched "$work/tier-requested.txt" copy --from "$from" --to "$to_write"; then
    nse_warn "a batched copy from '$from' failed; retrying per object to classify it"
    local p
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # KEEP THE STDERR. This used to be `>/dev/null 2>&1`, and then the code
      # announced "a transport, authentication or integrity failure" -- naming
      # three possibilities after discarding the only line that tells them
      # apart. Nix says which: a signature refusal reads "lacks a signature by
      # a trusted key", and that is a POLICY outcome, not an outage. Guessing
      # between them is the same defect as guessing absence from silence.
      local errf=$work/tier-copy-error.txt
      if nse_nix copy --from "$from" --to "$to_write" "$p" >/dev/null 2>"$errf"; then continue; fi
      local nixsaid; nixsaid=$(tr '\n' ' ' < "$errf" | sed 's/  */ /g' | cut -c1-400)
      printf '%s\t%s\n' "$p" "$nixsaid" >> "$work/tier-copy-failures.tsv"
      # Signature refusals are classified, not lumped in with outages. The
      # tier is reachable and answering; this store is simply not trusted to
      # supply this object under the current configuration.
      if printf '%s' "$nixsaid" | grep -qiE 'lacks a signature|untrusted|not trusted|signature'; then
        nse_die "the binary tier '$from' would not supply $p because Nix refused its
       signature: $nixsaid
       That is a TRUST decision, not an absence and not an outage. Supply the
       corresponding public key (--extra-nix-config 'trusted-public-keys = ...')
       if this tier is meant to be trusted; this tool will not disable signature
       checking for an ordinary binary tier on your behalf.
       SIGNATURE_UNTRUSTED."
      fi
      # Ask the source again about this one object. THREE outcomes, not two:
      # it still claims to hold it, it has revised its claim, or it did not
      # answer at all. Only the middle one is a legitimate absence.
      #
      # The old form ran the probe in a pipeline and read "grep found nothing"
      # as "the tier says it does not have it" -- so a tier that had stopped
      # answering (503, expired credential, DNS gone) got its outage recorded
      # as a revised absence, and the acceptance build was then told it was
      # free to rebuild the object. That is the exact laundering this whole
      # section exists to prevent, one level below where it was prevented.
      local reprobe probe_rc=0
      reprobe=$(printf '%s\n' "$p" | nse_store_present "$from") || probe_rc=$?
      if [ "$probe_rc" -ne 0 ]; then
        nse_die "the binary tier '$from' would not hand over $p and then did not
       answer whether it holds it (observation exit $probe_rc). An unanswered
       question is not a 'no'. Nix said: $nixsaid
       BINARY_TIER_ERROR."
      fi
      if printf '%s\n' "$reprobe" | grep -qxF "$p"; then
        nse_die "the binary tier '$from' still claims to hold $p but will not hand it over.
       Nix said: $nixsaid
       That is not an absence, and recording it as something the tier lacks
       would turn an outage into a statistic. BINARY_TIER_ERROR."
      fi
      printf '%s\n' "$p" >> "$work/tier-revised-absent.txt"
    done < "$work/tier-requested.txt"
  fi

  # What is in the replica is a fact about the replica, asked of the replica --
  # not "the copy command returned 0". `nix copy` is recursive, so the store
  # may hold more than these; only the requested roots are counted here.
  nse_observe_present "$to_read" \
    "$work/tier-requested.txt" "$work/replica-set.txt" \
    "what actually arrived in the binary replica"

  LC_ALL=C comm -23 "$work/tier-requested.txt" "$work/replica-set.txt" \
    > "$work/tier-claimed-not-materialised.txt"
  local n_gap; n_gap=$(wc -l < "$work/tier-claimed-not-materialised.txt")
  if [ "$n_gap" -ne 0 ]; then
    nse_warn "the binary tier claimed $n_gap object(s) it did not deliver:"
    head -3 "$work/tier-claimed-not-materialised.txt" >&2
    # Only a revised absence explains a gap. Anything else is unexplained, and
    # an unexplained gap is not evidence of anything.
    if [ -n "$(LC_ALL=C comm -23 "$work/tier-claimed-not-materialised.txt" \
                 <(LC_ALL=C sort -u "$work/tier-revised-absent.txt"))" ]; then
      nse_die "objects vanished between the tier's presence answer and the copy,
       and the tier did not revise its answer for them. The gap is unexplained,
       so it cannot be recorded as 'the tier does not have it'. BINARY_TIER_ERROR."
    fi
  fi
  return 0
}

# Copy one path set to one destination, splitting it by which store actually
# has the bytes. Batched: never one `nix copy` per path, and never one command
# line long enough to hit ARG_MAX.
nse_copy_set() {
  local set_file=$1 dest=$2 label=$3 staging=$4 work=$5
  local from_staging=$work/$label-from-staging.txt
  local from_host=$work/$label-from-host.txt

  LC_ALL=C comm -12 "$set_file" "$work/staging-requisites.txt" > "$from_staging"
  LC_ALL=C comm -23 "$set_file" "$work/staging-requisites.txt" > "$from_host"

  nse_log "$label: copying $(wc -l < "$from_staging") paths from staging, $(wc -l < "$from_host") from host store -> $dest"

  if [ -s "$from_staging" ]; then
    nse_nix_batched "$from_staging" copy --from "$staging" --to "$dest" --no-check-sigs \
      || nse_die "nix copy from staging store to $dest failed"
  fi
  if [ -s "$from_host" ]; then
    nse_nix_batched "$from_host" copy --to "$dest" --no-check-sigs \
      || nse_die "nix copy from host store to $dest failed"
  fi
}

# Join discovery.json with what is actually in the escrow, and with what the
# build plan actually required. Canonical + deterministic: no timestamps here.
nse_manifest() {
  local disc=$NSE_DIR/discovery.json
  local work=$NSE_DIR/work

  [ -f "$work/staging-out-paths.txt" ] \
    || nse_die "missing $work/staging-out-paths.txt; run 'nix-source-escrow preserve' first"

  nse_log "generating manifest"

  # present-in-escrow: asked of the escrow itself, so this works for a file://
  # directory and for an Attic/S3/HTTPS cache without a second code path.
  jq -r '(.flakeInputs[].storePath), (.sources[] | select(.storePath != null) | .storePath)' "$disc" \
    | LC_ALL=C sort -u > "$work/manifest-candidates.txt"
  nse_observe_present "$NSE_SUBSTITUTER_URL" \
    "$work/manifest-candidates.txt" "$work/escrow-present.txt" \
    "which manifest objects the escrow holds"

  local backend; backend=$(nse_backend_name "$NSE_STORE_URL")
  local f
  for f in tier-candidates tier-present tier-requested replica-set \
           tier-claimed-not-materialised not-provided-set; do
    [ -f "$work/$f.txt" ] || : > "$work/$f.txt"
  done
  [ -f "$work/tier-copy-failures.tsv" ] || : > "$work/tier-copy-failures.tsv"

  jq -n \
    --slurpfile disc "$disc" \
    --arg backend "$backend" \
    --arg guarantee "$NSE_GUARANTEE" \
    --arg storeUrl "$(nse_url_strip_query "$NSE_STORE_URL")" \
    --arg substituterUrl "$NSE_SUBSTITUTER_URL" \
    --arg replicaUrl "$([ -s "$work/replica-set.txt" ] && printf '%s' "$NSE_REPLICA_URL")" \
    --arg tierUrl "$NSE_BINARY_TIER" \
    --rawfile tierCandidates "$work/tier-candidates.txt" \
    --rawfile tierPresent    "$work/tier-present.txt" \
    --rawfile tierRequested  "$work/tier-requested.txt" \
    --rawfile tierGap        "$work/tier-claimed-not-materialised.txt" \
    --rawfile replicaSet  "$work/replica-set.txt" \
    --rawfile notProvided "$work/not-provided-set.txt" \
    --rawfile copyFailures "$work/tier-copy-failures.tsv" \
    --arg compression "${NSE_COMPRESSION:-zstd}" \
    --rawfile present  "$work/escrow-present.txt" \
    --rawfile realised "$work/staging-requisites.txt" \
    --rawfile outpaths "$work/staging-out-paths.txt" \
    '
    ($present  | split("\n") | map(select(length>0)) | INDEX(.)) as $E |
    ($realised | split("\n") | map(select(length>0)) | INDEX(.)) as $R |
    $disc[0] as $d |

    ( $d.flakeInputs | map(
        . + { escrow: { backend: $backend,
                        present: (($E[.storePath] // null) != null) } } ) ) as $inputs |

    ( $d.sources | map(
        . + {
          escrow: { backend: $backend,
                    present: (if .storePath == null then false
                              else ($E[.storePath] // null) != null end) },
          plan: {
            # A fixed-output source that the accepted build plan never realises
            # (because its consumer is substituted as a prebuilt binary) is
            # discovered but deliberately not preserved. Saying so is the point.
            requiredByPlan: (if .storePath == null then false
                             else ($R[.storePath] // null) != null end)
          }
        }
        | .escrow.status = (
            if .plan.requiredByPlan and .escrow.present then "COVERED"
            elif .plan.requiredByPlan and (.escrow.present|not) then "MISSING"
            elif .escrow.present then "COVERED_NOT_REQUIRED"
            else "NOT_REQUIRED_BY_PLAN" end) ) ) as $sources |

    {
      schemaVersion: 3,
      installable: $d.installable,
      flakeRef: $d.flakeRef,
      storeDir: $d.storeDir,
      guarantee: $guarantee,
      # Which shape of `nix derivation show` this graph was read from. The
      # report printed "unrecorded, 0 derivations" because the manifest never
      # carried it -- a reporting gap in the very field added to make the
      # 2.24.9 defect visible.
      derivationDocument: $d.derivationDocument,
      topLevelDerivation: $d.topLevelDerivation,
      expectedOutputs: ($outpaths | split("\n") | map(select(length>0)) | sort),
      escrow: { backend: $backend, url: $storeUrl, storeUrl: $storeUrl,
                substituterUrl: $substituterUrl,
                binaryReplicaUrl: (if $replicaUrl == "" then null else $replicaUrl end),
                compression: $compression },
      binaryTier: (if $guarantee != "source-origin-independence" then null else
        def n($s): ($s | split("\n") | map(select(length>0)) | length);
        {
          url: $tierUrl,
          # Probing and materialising are separate observations. "The tier says
          # it has X" and "X arrived" were once one number, and that number was
          # wrong: `nix path-info --json` answers "path": null for an object it
          # does not have, so 227 candidates became 227 "supplied", including
          # one this machine had just built. They are counted apart now, and a
          # non-zero claimedButNotMaterialized is visible in the evidence even
          # when the acceptance build goes on to succeed without those objects.
          candidates:                n($tierCandidates),
          present:                   n($tierPresent),
          materializationRequested:  n($tierRequested),
          materializedRoots:         n($replicaSet),
          claimedButNotMaterialized: n($tierGap),
          notProvided:               n($notProvided)
        } end),
      flakeInputs: $inputs,
      sources: $sources,
      evalTimeFetches: $d.evalTimeFetches,
      counts: ($d.counts + {
        flakeInputsPresent: ([$inputs[]|select(.escrow.present)]|length),
        sourcesRequiredByPlan: ([$sources[]|select(.plan.requiredByPlan)]|length),
        sourcesCoveredInEscrow: ([$sources[]|select(.escrow.status=="COVERED")]|length),
        sourcesMissing: ([$sources[]|select(.escrow.status=="MISSING")]|length),
        sourcesNotRequiredByPlan: ([$sources[]|select(.plan.requiredByPlan|not)]|length)
      })
    }' | nse_json_canonical | nse_write_file "$NSE_DIR/manifest.json"

  jq -r '
    "GUARANTEE=\(.guarantee)",
    "OBJECTS_IN_MANIFEST=\(.counts.sources + .counts.flakeInputs)",
    "FLAKE_INPUTS_PRESERVED=\(.counts.flakeInputsPresent)/\(.counts.flakeInputs)",
    "SOURCES_REQUIRED_BY_PLAN=\(.counts.sourcesRequiredByPlan)",
    "SOURCES_PRESERVED=\(.counts.sourcesCoveredInEscrow)",
    "SOURCES_MISSING=\(.counts.sourcesMissing)",
    "SOURCES_DISCOVERED_BUT_NOT_REQUIRED=\(.counts.sourcesNotRequiredByPlan)"
  ' "$NSE_DIR/manifest.json" >&2
}
