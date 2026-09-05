# shellcheck shell=bash
# TRUST: a black-box measurement of what the *installed* Nix actually requires
# before it will accept an object out of our escrow.
#
# We do not add signing keys because it is customary. We measure which classes
# of object need one, and only then decide.

# Try to pull one path out of the escrow into a throwaway store under a given
# trusted-public-keys setting. Echoes ok|denied and writes the log.
nse_trust_try() {
  local path=$1 keys=$2 log=$3
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/nse-trust.XXXXXX") \
    || nse_die "mktemp -d failed for the trust probe"
  local rc=0
  NIX_CONFIG="experimental-features = nix-command flakes
require-sigs = true
trusted-public-keys = $keys
build-users-group =
require-drop-supplementary-groups = false
${NSE_EXTRA_NIX_CONFIG:-}" \
    nix copy --from "$NSE_SUBSTITUTER_URL" --to "$tmp" "$path" > "$log" 2>&1 || rc=$?
  nse_rm_store "$tmp"
  if [ "$rc" -eq 0 ]; then printf 'ok\n'; else printf 'denied\n'; fi
}

nse_trust_probe() {
  local manifest=$NSE_DIR/manifest.json
  local work=$NSE_DIR/work
  [ -f "$manifest" ] || nse_die "no manifest.json; run 'nix-source-escrow preserve' first"
  mkdir -p "$work" "$NSE_DIR/evidence"

  nse_step "TRUST probe (require-sigs = true throughout)"

  local nixos_key=${NSE_NIXOS_KEY:-cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=}

  # ---- pick one representative object per class ---------------------------
  # Candidates in priority order (sources first, so the "source escrow needs no
  # signing" claim is made about an actual source), classified from the
  # escrow's own path metadata rather than from files in a directory.
  {
    jq -r '(.sources[] | select(.escrow.present and .plan.requiredByPlan) | .storePath),
           (.expectedOutputs[]),
           (.flakeInputs[] | select(.escrow.present) | .storePath)' "$manifest"
    jq -r '(.escrowPaths // .paths)[]' "$NSE_DIR/closure.json"
  } | awk 'NF && !seen[$0]++' > "$work/trust-candidates.txt"

  LC_ALL=C sort -u "$work/trust-candidates.txt" > "$work/trust-candidates-sorted.txt"
  nse_observe_present "$NSE_SUBSTITUTER_URL" \
    "$work/trust-candidates-sorted.txt" "$work/trust-present.txt" \
    "which escrowed objects are available to probe for trust"
  nse_store_meta "$NSE_SUBSTITUTER_URL" < "$work/trust-present.txt" \
    > "$work/trust-meta.jsonl"

  # Sample selection happens entirely in jq, walking the candidate list in
  # priority order. The previous version built a bash associative array from a
  # TSV with `read -r p ca sigs` under IFS=$'\t' -- and a signed object has an
  # EMPTY ca field, so `path<TAB><TAB>1` collapsed to two fields, the signature
  # count landed in `ca`, and every signed and unsigned object was classified
  # content-addressed. The probe then reported "skipped" for three of its five
  # cases while the composition counter in the same report, parsing the same
  # file correctly, printed 53 and 1. Nothing here parses fields by hand.
  local sample_ca="" sample_signed="" sample_unsigned=""
  local -a nse_samples
  mapfile -t nse_samples < <(
    jq -r -n "$NSE_JQ_CLASSIFY"'
      ( [ inputs ] | map({key: .path, value: .}) | from_entries ) as $m
      | ( $order | split("\n") | map(select(length > 0)) ) as $cands
      | def pick($want): [ $cands[] | select( ($m[.] // null) != null
                                              and ($m[.] | nse_class) == $want ) ][0] // "";
        [ pick("ca-fixed"), pick("signed"), pick("unsigned") ] | .[]
    ' --rawfile order "$work/trust-candidates.txt" "$work/trust-meta.jsonl")
  sample_ca=${nse_samples[0]:-}
  sample_signed=${nse_samples[1]:-}
  sample_unsigned=${nse_samples[2]:-}

  [ -n "$sample_ca" ] || nse_die "trust probe: no content-addressed source object found in the escrow"

  nse_log "content-addressed sample : ${sample_ca:-none}"
  nse_log "signed sample            : ${sample_signed:-none}"
  nse_log "unsigned input-addressed : ${sample_unsigned:-none}"

  # ---- the experiment ------------------------------------------------------
  # Note the escrow itself is never signed and its key is never trusted, so a
  # success below can only come from the object being self-authenticating or
  # from a signature it inherited from cache.nixos.org.
  local r_ca_nokeys r_ca_nixoskey r_signed_nixoskey r_signed_nokeys r_unsigned

  r_ca_nokeys=$(nse_trust_try "$sample_ca" "" "$work/trust-ca-nokeys.log")
  r_ca_nixoskey=$(nse_trust_try "$sample_ca" "$nixos_key" "$work/trust-ca-nixoskey.log")

  if [ -n "$sample_signed" ]; then
    r_signed_nixoskey=$(nse_trust_try "$sample_signed" "$nixos_key" "$work/trust-signed-nixoskey.log")
    r_signed_nokeys=$(nse_trust_try "$sample_signed" "" "$work/trust-signed-nokeys.log")
  else
    r_signed_nixoskey=skipped; r_signed_nokeys=skipped
  fi

  if [ -n "$sample_unsigned" ]; then
    r_unsigned=$(nse_trust_try "$sample_unsigned" "$nixos_key" "$work/trust-unsigned.log")
  else
    r_unsigned=skipped
  fi

  local source_sig_required=unknown
  case $r_ca_nokeys in
    ok)     source_sig_required=false ;;
    denied) source_sig_required=true ;;
  esac

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg substituter "$NSE_SUBSTITUTER_URL" \
    --arg sampleCa "$sample_ca" --arg sampleSigned "$sample_signed" \
    --arg sampleUnsigned "$sample_unsigned" \
    --arg caNoKeys "$r_ca_nokeys" --arg caNixosKey "$r_ca_nixoskey" \
    --arg signedNixosKey "$r_signed_nixoskey" --arg signedNoKeys "$r_signed_nokeys" \
    --arg unsignedInputAddressed "$r_unsigned" \
    --arg sourceSigRequired "$source_sig_required" \
    --argjson provenance "$(nse_provenance)" \
    '{schemaVersion:3, kind:"trust-probe", timestamp:$ts, provenance:$provenance,
      substituterUrl:$substituter,
      requireSigs:true, escrowIsSigned:false, escrowKeyInTrustedKeys:false,
      signingKeysCreated:0,
      samples:{contentAddressedSource:$sampleCa, signedInputAddressed:$sampleSigned,
               unsignedInputAddressed:$sampleUnsigned},
      results:{
        contentAddressedSource_noTrustedKeys:$caNoKeys,
        contentAddressedSource_cacheNixosOrgKey:$caNixosKey,
        signedInputAddressed_cacheNixosOrgKey:$signedNixosKey,
        signedInputAddressed_noTrustedKeys:$signedNoKeys,
        unsignedInputAddressed_cacheNixosOrgKey:$unsignedInputAddressed},
      conclusion:{sourceSignatureRequired:$sourceSigRequired}}' \
    | nse_json_canonical | nse_write_file "$NSE_DIR/evidence/trust.json"

  jq -r '
    "TRUST_REQUIRE_SIGS=\(.requireSigs)",
    "TRUST_ESCROW_SIGNED=\(.escrowIsSigned)",
    "TRUST_ESCROW_KEY_TRUSTED=\(.escrowKeyInTrustedKeys)",
    "CA_SOURCE_WITH_NO_TRUSTED_KEYS=\(.results.contentAddressedSource_noTrustedKeys)",
    "CA_SOURCE_WITH_CACHE_NIXOS_KEY=\(.results.contentAddressedSource_cacheNixosOrgKey)",
    "SIGNED_PATH_WITH_CACHE_NIXOS_KEY=\(.results.signedInputAddressed_cacheNixosOrgKey)",
    "SIGNED_PATH_WITH_NO_TRUSTED_KEYS=\(.results.signedInputAddressed_noTrustedKeys)",
    "UNSIGNED_INPUT_ADDRESSED_PATH=\(.results.unsignedInputAddressed_cacheNixosOrgKey)",
    "SOURCE_SIGNATURE_REQUIRED=\(.conclusion.sourceSignatureRequired)"
  ' "$NSE_DIR/evidence/trust.json"
}
