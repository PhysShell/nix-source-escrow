# shellcheck shell=bash
# PRESERVE: put everything the accepted build needs into a locally controlled
# store, using stock Nix primitives only (nix flake archive / nix copy /
# a file:// binary cache). No custom storage protocol.

nse_cache_url() {
  # A file:// binary cache. Refuse exotic paths rather than silently producing
  # a malformed URL.
  case $NSE_CACHE in
    *[!A-Za-z0-9._/-]*)
      nse_die "escrow cache path contains characters that are unsafe in a file:// URL: '$NSE_CACHE'
       Use --escrow-dir to pick a path matching [A-Za-z0-9._/-]+ ." ;;
  esac
  printf 'file://%s?compression=%s\n' "$NSE_CACHE" "${NSE_COMPRESSION:-zstd}"
}

nse_cache_url_plain() {
  case $NSE_CACHE in
    *[!A-Za-z0-9._/-]*) nse_die "unsafe escrow cache path: '$NSE_CACHE'" ;;
  esac
  printf 'file://%s\n' "$NSE_CACHE"
}

nse_preserve() {
  local work=$NSE_DIR/work
  local staging=$work/staging
  local disc=$NSE_DIR/discovery.json
  [ -f "$disc" ] || nse_die "no discovery.json; run 'nix-source-escrow discover' first"

  mkdir -p "$NSE_CACHE" "$staging" "$work"
  local flakeref; flakeref=$(nse_flakeref_of "$NSE_INSTALLABLE")

  nse_step "PRESERVE $NSE_INSTALLABLE -> $NSE_CACHE"

  if [ "${NSE_FRESH_STAGING:-0}" = 1 ]; then
    nse_log "wiping staging store (--fresh-staging)"
    chmod -R u+w "$staging" 2>/dev/null || :
    rm -rf "$staging"; mkdir -p "$staging"
  fi

  # ---- 1. flake input material via the stock mechanism ---------------------
  nse_log "nix flake archive -> escrow"
  nse_nix flake archive --json --to "$(nse_cache_url)" "$flakeref" \
    > "$work/flake-archive-preserve.json" \
    || nse_die "nix flake archive --to failed"

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
  nse_log "computing preservation set"
  {
    nix-store --store "$staging" --query --requisites --include-outputs "$top_drv" \
      || nse_die "cannot compute requisites of $top_drv in staging store"
    jq -r '.flakeInputs[].storePath, .flakeSourcePath' "$disc"
  } | LC_ALL=C sort -u > "$work/preserve-set.txt"

  local n_set; n_set=$(wc -l < "$work/preserve-set.txt")
  nse_log "preservation set: $n_set store paths"

  # Anything in the set that is not in staging must come from the host store
  # (flake inputs land there when evaluation happened outside the staging
  # store). Split the set so each half is copied from a source that has it.
  : > "$work/from-staging.txt"; : > "$work/from-host.txt"
  local p
  while IFS= read -r p; do
    if nix path-info --store "$staging" "$p" >/dev/null 2>&1; then
      printf '%s\n' "$p" >> "$work/from-staging.txt"
    else
      printf '%s\n' "$p" >> "$work/from-host.txt"
    fi
  done < "$work/preserve-set.txt"

  nse_log "copying $(wc -l < "$work/from-staging.txt") paths from staging, $(wc -l < "$work/from-host.txt") from host store"

  if [ -s "$work/from-staging.txt" ]; then
    # shellcheck disable=SC2046
    nse_nix copy --from "$staging" --to "$(nse_cache_url)" --no-check-sigs \
      $(tr '\n' ' ' < "$work/from-staging.txt") \
      || nse_die "nix copy from staging store to escrow failed"
  fi
  if [ -s "$work/from-host.txt" ]; then
    # shellcheck disable=SC2046
    nse_nix copy --to "$(nse_cache_url)" --no-check-sigs \
      $(tr '\n' ' ' < "$work/from-host.txt") \
      || nse_die "nix copy from host store to escrow failed"
  fi

  jq -R . < "$work/preserve-set.txt" | jq -s '{schemaVersion:1, paths: (.|sort)}' \
    | nse_json_canonical | nse_write_file "$NSE_DIR/closure.json"

  nse_manifest
}

# Join discovery.json with what is actually in the escrow, and with what the
# build plan actually required. Canonical + deterministic: no timestamps here.
nse_manifest() {
  local disc=$NSE_DIR/discovery.json
  local staging=$NSE_DIR/work/staging
  local work=$NSE_DIR/work

  [ -f "$work/staging-out-paths.txt" ] \
    || nse_die "missing $work/staging-out-paths.txt; run 'nix-source-escrow preserve' first"

  nse_log "generating manifest"

  # present-in-escrow: <hashpart> of every narinfo in the cache
  find "$NSE_CACHE" -maxdepth 1 -name '*.narinfo' -printf '%f\n' 2>/dev/null \
    | sed 's/\.narinfo$//' | LC_ALL=C sort > "$work/escrow-hashparts.txt"

  # realised-by-plan: store paths valid in the staging store
  if [ -d "$staging/nix/store" ]; then
    nix-store --store "$staging" --query --requisites --include-outputs \
      "$(jq -r '.topLevelDerivation' "$disc")" 2>/dev/null \
      | LC_ALL=C sort -u > "$work/realised.txt" \
      || nse_die "cannot enumerate realised paths in staging store"
  else
    : > "$work/realised.txt"
  fi

  jq -n \
    --slurpfile disc "$disc" \
    --arg backend "local-file-binary-cache" \
    --arg cache "$NSE_CACHE" \
    --arg compression "${NSE_COMPRESSION:-zstd}" \
    --rawfile escrowed "$work/escrow-hashparts.txt" \
    --rawfile realised "$work/realised.txt" \
    --rawfile outpaths "$work/staging-out-paths.txt" \
    '
    def hashpart($p): ($p | sub("^.*/";"") | split("-")[0]);
    ($escrowed | split("\n") | map(select(length>0)) | INDEX(.)) as $E |
    ($realised | split("\n") | map(select(length>0)) | INDEX(.)) as $R |
    $disc[0] as $d |

    ( $d.flakeInputs | map(
        . + { escrow: { backend: $backend,
                        present: (($E[hashpart(.storePath)] // null) != null) } } ) ) as $inputs |

    ( $d.sources | map(
        (if .storePath == null then null else hashpart(.storePath) end) as $hp |
        . + {
          escrow: { backend: $backend,
                    present: (if $hp == null then false else ($E[$hp] // null) != null end) },
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
      schemaVersion: 1,
      installable: $d.installable,
      flakeRef: $d.flakeRef,
      storeDir: $d.storeDir,
      topLevelDerivation: $d.topLevelDerivation,
      expectedOutputs: ($outpaths | split("\n") | map(select(length>0)) | sort),
      escrow: { backend: $backend, url: ("file://" + $cache), compression: $compression },
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
    "OBJECTS_IN_MANIFEST=\(.counts.sources + .counts.flakeInputs)",
    "FLAKE_INPUTS_PRESERVED=\(.counts.flakeInputsPresent)/\(.counts.flakeInputs)",
    "SOURCES_REQUIRED_BY_PLAN=\(.counts.sourcesRequiredByPlan)",
    "SOURCES_PRESERVED=\(.counts.sourcesCoveredInEscrow)",
    "SOURCES_MISSING=\(.counts.sourcesMissing)",
    "SOURCES_DISCOVERED_BUT_NOT_REQUIRED=\(.counts.sourcesNotRequiredByPlan)"
  ' "$NSE_DIR/manifest.json" >&2
}
