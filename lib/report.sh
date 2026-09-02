# shellcheck shell=bash
# Environment reconnaissance and the final evidence report.

nse_env() {
  mkdir -p "$NSE_DIR/evidence"
  local trusted; trusted=$(nix store info --json 2>/dev/null | jq -r '.trusted // false')
  local wsl=false
  grep -qi microsoft /proc/version && wsl=true
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg nixVersion "$(nix --version)" \
    --arg kernel "$(uname -sr)" \
    --arg os "$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)" \
    --arg system "$(nix eval --impure --raw --expr builtins.currentSystem)" \
    --arg storeDir "$(nse_store_dir)" \
    --argjson clientTrusted "$trusted" \
    --argjson wsl "$wsl" \
    --arg experimental "$(nix config show experimental-features)" \
    --arg substituters "$(nix config show substituters)" \
    --arg requireSigs "$(nix config show require-sigs)" \
    --arg sandbox "$(nix config show sandbox)" \
    --arg hashedMirrors "$(nix config show hashed-mirrors)" \
    '{schemaVersion:1, kind:"environment", timestamp:$ts,
      nixVersion:$nixVersion, system:$system, storeDir:$storeDir, kernel:$kernel, os:$os,
      wsl2:$wsl, clientIsTrustedUser:$clientTrusted,
      nixConfig:{experimentalFeatures:$experimental, substituters:$substituters,
                 requireSigs:$requireSigs, sandbox:$sandbox, hashedMirrors:$hashedMirrors}}' \
    | nse_json_canonical | nse_write_file "$NSE_DIR/evidence/environment.json"

  jq -r '"NIX_VERSION=" + (.nixVersion|sub("^nix \\(Nix\\) ";"")),
         "SYSTEM=" + .system,
         "EXECUTION_ENV=" + (if .wsl2 then "WSL2/" else "" end) + .os,
         "CLIENT_IS_TRUSTED_USER=" + (.clientIsTrustedUser|tostring)' \
    "$NSE_DIR/evidence/environment.json"
}

nse_report() {
  local e=$NSE_DIR/evidence
  local m=$NSE_DIR/manifest.json
  local f
  for f in "$e/environment.json" "$m"; do
    [ -f "$f" ] || nse_die "missing $f; run 'nix-source-escrow escrow <installable>' first"
  done

  local vj=$e/verify.json tj=$e/trust.json oj=$e/origin-independence.json
  [ -f "$vj" ] || vj=""
  [ -f "$tj" ] || tj=""
  [ -f "$oj" ] || oj=""

  # Discovery completeness depends on evidence from two stages: the static
  # enumeration, and the offline evaluation probe that runs inside the
  # acceptance test. Eval-time builtins.fetch* cannot be enumerated statically,
  # so without that probe completeness is UNVERIFIED -- never PASS.
  local eval_probe=absent isolation_mode=absent
  if [ -n "$oj" ]; then
    eval_probe=$(jq -r '.offlineEvalProbe // "absent"' "$oj")
    isolation_mode=$(jq -r '.isolationMode // "absent"' "$oj")
  fi

  {
    printf 'ENVIRONMENT\n'
    jq -r '"NIX_VERSION=" + (.nixVersion|sub("^nix \\(Nix\\) ";"")),
           "SYSTEM=" + .system,
           "HOST=Windows 11",
           "EXECUTION_ENV=" + (if .wsl2 then "WSL2/" else "" end) + .os,
           "KERNEL=" + .kernel,
           "CLIENT_IS_TRUSTED_USER=" + (.clientIsTrustedUser|tostring),
           "AMBIENT_REQUIRE_SIGS=" + .nixConfig.requireSigs,
           "AMBIENT_HASHED_MIRRORS=" + (if .nixConfig.hashedMirrors == "" then "(unset)" else .nixConfig.hashedMirrors end)' \
      "$e/environment.json"

    printf '\nDISCOVERY\n'
    jq -r --arg evalProbe "$eval_probe" --arg isoMode "$isolation_mode" '
           "INSTALLABLE=" + .installable,
           "FLAKE_INPUTS=\(.counts.flakeInputs)",
           "  INPUT_TREE_EDGES_WALKED=\(.counts.flakeInputEdgesWalked)",
           "  INPUTS_UNRESOLVED_IN_LOCK=\(.counts.flakeInputsUnknown)",
           "FOD_SOURCES=\(.counts.sources)",
           "COVERED=\(.counts.sourcesCovered)",
           "EXTERNAL_RECOVERY=\(.counts.sourcesExternalRecovery)",
           "QUARANTINED=\(.counts.sourcesQuarantined)",
           "UNKNOWN=\(.counts.sourcesUnknown)",
           "UNSUPPORTED=\(.counts.sourcesUnsupported)",
           "  HASH_MODE_FLAT=\(.counts.sourcesFlatHash)  HASH_MODE_NAR=\(.counts.sourcesNarHash)",
           "  WITH_POSTFETCH=\(.counts.sourcesWithPostFetch)",
           "  ON_KNOWN_FORGE=\(.counts.sourcesOnKnownForge)",
           "IFD_DETECTED=" + .evalTimeFetches.ifd.status,
           "EVAL_TIME_FETCH_STATIC_ENUMERATION=" + .evalTimeFetches.staticEnumeration,
           "EVAL_TIME_FETCH_OFFLINE_PROBE=" + $evalProbe,
           "ESCROW_DISCOVERY_COMPLETE=" +
             (if (.counts.sourcesUnknown != 0 or .counts.sourcesUnsupported != 0
                  or .counts.flakeInputsUnknown != 0 or .evalTimeFetches.ifd.status != "absent")
              then "PARTIAL"
              elif ($evalProbe != "clean" or $isoMode != "namespaces")
              then "UNVERIFIED"
              else "PASS" end)' "$m"
    jq -r --arg evalProbe "$eval_probe" --arg isoMode "$isolation_mode" '
           if .counts.sourcesUnknown != 0
             then "  gap: \(.counts.sourcesUnknown) source(s) with no attributable origin" else empty end,
           if .counts.sourcesUnsupported != 0
             then "  gap: \(.counts.sourcesUnsupported) source(s) whose output path is not statically resolvable" else empty end,
           if .counts.flakeInputsUnknown != 0
             then "  gap: \(.counts.flakeInputsUnknown) flake input(s) could not be resolved to a lock node" else empty end,
           if .evalTimeFetches.ifd.status != "absent"
             then "  gap: import-from-derivation is present on this evaluation path" else empty end,
           if ($evalProbe != "clean" or $isoMode != "namespaces")
             then "  gap: eval-time builtins.fetch* cannot be enumerated statically and the offline evaluation probe has not passed under real isolation (probe=\($evalProbe), isolation=\($isoMode)); run test-origin-independence"
             else "  note: eval-time builtins.fetch* are unenumerable statically, but evaluation succeeded offline with an empty cache under network isolation, so none needed the network" end,
           if .counts.sourcesExternalRecovery != 0
             then "  note: \(.counts.sourcesExternalRecovery) fixed-output source(s) have no origin URL at all (nixpkgs minimal-bootstrap); they can never be re-fetched upstream, only restored from a cache/escrow" else empty end' "$m"

    printf '\nESCROW\n'
    jq -r '"BACKEND=" + .escrow.backend,
           "URL=" + .escrow.url,
           "COMPRESSION=" + .escrow.compression,
           "FLAKE_INPUTS_PRESERVED=\(.counts.flakeInputsPresent)/\(.counts.flakeInputs)",
           "SOURCES_REQUIRED_BY_PLAN=\(.counts.sourcesRequiredByPlan)",
           "SOURCES_PRESERVED=\(.counts.sourcesCoveredInEscrow)",
           "SOURCES_MISSING=\(.counts.sourcesMissing)",
           "SOURCES_DISCOVERED_NOT_REQUIRED_BY_PLAN=\(.counts.sourcesNotRequiredByPlan)"' "$m"
    [ -f "$NSE_DIR/closure.json" ] && jq -r '"OBJECTS_PRESERVED=\(.paths|length)"' "$NSE_DIR/closure.json"
    if [ -n "$vj" ]; then
      # Presence of a narinfo and integrity of a NAR are different claims, and
      # conflating them is how an escrow gets reported as verified when it is
      # merely populated.
      jq -r '"OBJECTS_PRESENT=\(.presence.closurePaths - .presence.missing)/\(.presence.closurePaths)",
             "OBJECTS_NAR_VERIFIED=\(.narIntegrity.pathsChecked)/\(.presence.closurePaths)",
             "NAR_INTEGRITY_SCOPE=\(.narIntegrity.scope)",
             "NAR_INTEGRITY=\(.narIntegrity.status)",
             "CONTENT_IDENTITY_VERIFIED=\(.contentIdentity.verified)",
             "CONTENT_IDENTITY_MISMATCH=\(.contentIdentity.mismatched)",
             "ESCROW_VERIFY=\(.status)"' "$vj"
    fi

    printf '\nTRUST\n'
    if [ -n "$tj" ]; then
      jq -r '"REQUIRE_SIGS_DURING_PROBE=true",
             "ESCROW_IS_SIGNED=false",
             "ESCROW_KEY_IN_TRUSTED_PUBLIC_KEYS=false",
             "SIGNING_KEYS_CREATED=0",
             "  content-addressed source, no trusted keys      -> \(.results.contentAddressedSource_noTrustedKeys)",
             "  content-addressed source, cache.nixos.org key  -> \(.results.contentAddressedSource_cacheNixosOrgKey)",
             "  input-addressed + signed, cache.nixos.org key  -> \(.results.signedInputAddressed_cacheNixosOrgKey)",
             "  input-addressed + signed, no trusted keys      -> \(.results.signedInputAddressed_noTrustedKeys)",
             "  input-addressed + unsigned, cache.nixos.org key-> \(.results.unsignedInputAddressed_cacheNixosOrgKey)",
             "SOURCE_SIGNATURE_REQUIRED=\(.conclusion.sourceSignatureRequired)"' "$tj"
    fi
    if [ -n "$vj" ]; then
      jq -r '"ESCROW_OBJECTS_CONTENT_ADDRESSED=\(.trustComposition.contentAddressed)",
             "ESCROW_OBJECTS_SIGNATURE_ONLY=\(.trustComposition.signatureOnly)",
             "ESCROW_OBJECTS_UNSIGNED_INPUT_ADDRESSED=\(.trustComposition.unsignedInputAddressed)"' "$vj"
    fi
    if [ -n "$oj" ]; then
      jq -r '"TEST=" + (if .result=="PASS" then "PASS" else "FAIL" end)' "$oj"
    fi

    printf '\nNETWORK ACCEPTANCE\n'
    if [ -n "$oj" ]; then
      jq -r '"NETWORK_ISOLATION=" + .isolation,
             "ISOLATION_MODE=" + .isolationMode,
             "NSS_ISOLATION=" + .nssIsolation,
             "ORIGIN_HOSTS_PROVEN_UNREACHABLE=" + ((.originHostsProvenUnreachable|join(",")) | if .=="" then "none" else . end),
             "ORIGIN_HOSTS_REACHABLE=" + ((.originHostsReachable|join(",")) | if .=="" then "none" else . end),
             "CACHE_NIXOS_ORG_ALLOWED=" + ([.connectivity[]|select(.host=="cache.nixos.org")|(.reachableByName or .reachableByAddress)]|first|tostring),
             "OUR_ESCROW_ALLOWED=true",
             "SUBSTITUTERS_ONLY_ESCROW=" + (.substitutersOnlyEscrow|tostring),
             "EFFECTIVE_SUBSTITUTERS=" + .effectiveSubstituters,
             "PROBE_METHOD=curl by name and by address pre-resolved outside the namespace",
             "OFFLINE_EVAL_PROBE=" + .offlineEvalProbe,
             "HTTP_FETCHES_IN_BUILD_LOG=\(.httpFetchesInBuildLog)",
             "REQUIRED_SOURCES_PRESENT_AFTER_BUILD=\(.sourcesRestored)/\(.sourcesRequired)",
             "OUTPUT_PATH=" + .builtOutput,
             "OUTPUT_MATCHES_MANIFEST=" + (.outputMatches|tostring),
             "",
             "ORIGIN_INDEPENDENCE=" + .result' "$oj"
      jq -r 'if .reason then "REASON=" + .reason else empty end' "$oj"
      jq -r '.connectivity[] | "  probe \(.host) [\(.preResolvedAddress)]: byName=\(.reachableByName) (curl \(.curlExitByName)), byAddress=\(.reachableByAddress) (curl \(.curlExitByAddress))"' "$oj"
    else
      printf 'ORIGIN_INDEPENDENCE=NOT_RUN\n'
    fi
  } | tee "$e/report.txt"
}
