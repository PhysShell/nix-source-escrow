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

  if [ -s "$work/replica-set.txt" ]; then
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
    # FROM THE TIER, never from staging. This is the whole point: an object
    # copied out of the staging store proves that *this machine* could produce
    # it, which is not the claim SOURCE_ORIGIN_INDEPENDENCE makes.
    nse_log "replica: copying $(wc -l < "$work/replica-set.txt") paths from the approved binary tier $NSE_BINARY_TIER -> $replica_store"
    nse_nix_batched "$work/replica-set.txt" copy --from "$NSE_BINARY_TIER" --to "$replica_store" \
      || nse_die "copying the prebuilt tier from '$NSE_BINARY_TIER' failed"
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

# Decide what the approved binary tier has to supply, ask it, and write down
# the answer.
#
# The first version of this mode filled the replica with `preserve-set -
# escrow-set` copied out of the STAGING store, which quietly made the claim
# untrue: an object staging happened to build locally was served to the
# acceptance test as though the approved cache had it.
#
# The second version overcorrected. It read a cache signature on a staging path
# as proof the path had been SUBSTITUTED, and then refused the whole mode when
# the approved tier lacked such a path. Both halves of that were wrong. A
# signature is not proof of substitution -- Nix signs locally built paths too
# when `secret-key-files` is set -- and more importantly, "the previous staging
# run chose to download X" says nothing about whether X can be built. The mode
# already allows a rebuild for everything the tier does not hold, so a signed
# path has no special metaphysical status.
#
# So there is no heuristic here at all. The tier supplies what it has; whatever
# nobody holds is handed to nobody, and the acceptance build is the judge of
# whether it can be produced. That is a measurement, not a guess.
nse_binary_replica() {
  local work=$1

  LC_ALL=C comm -23 "$work/preserve-set.txt" "$work/escrow-set.txt" \
    > "$work/non-source-set.txt"

  # Derivations are asked of nobody: the acceptance test evaluates the flake
  # and instantiates them itself. Asking a binary cache for a .drv is a
  # category error.
  grep -v '\.drv$' "$work/non-source-set.txt" > "$work/tier-candidates.txt" || :

  nse_log "binary tier: asking $NSE_BINARY_TIER for $(wc -l < "$work/tier-candidates.txt") prebuilt objects"
  nse_store_present "$NSE_BINARY_TIER" < "$work/tier-candidates.txt" \
    | LC_ALL=C sort -u > "$work/replica-set.txt"
  LC_ALL=C comm -23 "$work/preserve-set.txt" \
    <(LC_ALL=C sort -u "$work/escrow-set.txt" "$work/replica-set.txt") \
    > "$work/not-provided-set.txt"

  nse_log "binary tier: $(wc -l < "$work/replica-set.txt") supplied, $(wc -l < "$work/not-provided-set.txt") provided to nobody (the test instantiates or rebuilds those)"
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
  nse_store_present "$NSE_SUBSTITUTER_URL" < "$work/manifest-candidates.txt" \
    | LC_ALL=C sort -u > "$work/escrow-present.txt"

  local backend; backend=$(nse_backend_name "$NSE_STORE_URL")
  local tier_candidates=$work/tier-candidates.txt
  [ -f "$tier_candidates" ] || : > "$tier_candidates"

  jq -n \
    --slurpfile disc "$disc" \
    --arg backend "$backend" \
    --arg guarantee "$NSE_GUARANTEE" \
    --arg storeUrl "$(nse_url_strip_query "$NSE_STORE_URL")" \
    --arg substituterUrl "$NSE_SUBSTITUTER_URL" \
    --arg replicaUrl "$([ -s "$work/replica-set.txt" ] && printf '%s' "$NSE_REPLICA_URL")" \
    --arg tierUrl "$NSE_BINARY_TIER" \
    --rawfile tierRequested "$tier_candidates" \
    --rawfile replicaSet  "$work/replica-set.txt" \
    --rawfile notProvided "$work/not-provided-set.txt" \
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
      topLevelDerivation: $d.topLevelDerivation,
      expectedOutputs: ($outpaths | split("\n") | map(select(length>0)) | sort),
      escrow: { backend: $backend, url: $storeUrl, storeUrl: $storeUrl,
                substituterUrl: $substituterUrl,
                binaryReplicaUrl: (if $replicaUrl == "" then null else $replicaUrl end),
                compression: $compression },
      binaryTier: (if $guarantee != "source-origin-independence" then null else {
        url: $tierUrl,
        # What we asked the tier for, what it supplied, and what is therefore
        # provided to nobody -- the acceptance build has to instantiate or
        # rebuild that last set, and whether it can is for the acceptance test
        # to answer, not for this stage to predict.
        pathsRequested:   ($tierRequested | split("\n") | map(select(length>0)) | length),
        pathsFromTier:    ($replicaSet    | split("\n") | map(select(length>0)) | length),
        pathsNotProvided: ($notProvided   | split("\n") | map(select(length>0)) | length)
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
