# shellcheck shell=bash
# Environment reconnaissance and the final evidence report.

# What machine is this, measured rather than declared. An earlier version of
# this file printed `HOST=Windows 11` as a literal in every report on every
# machine -- in a tool whose stated rule is "the report states what was
# demonstrated, not what was intended". Nothing here is a constant.
nse_detect_host() {
  local kind method virt
  if [ -n "${NSE_HOST:-}" ]; then
    kind=$NSE_HOST; method="NSE_HOST (operator-supplied)"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    # The Windows build number is not visible from the Linux guest, so we do
    # not invent one.
    kind="WSL2 guest (Windows host, version not observable from Linux)"
    method="/proc/version matches 'microsoft'"
  elif command -v systemd-detect-virt >/dev/null 2>&1 \
       && virt=$(systemd-detect-virt 2>/dev/null) && [ "$virt" != none ]; then
    kind="virtualised ($virt)"; method="systemd-detect-virt"
  elif [ -f /.dockerenv ]; then
    kind="container"; method="/.dockerenv exists"
  else
    kind="not determined"; method="no positive indicator found"
  fi
  jq -n --arg kind "$kind" --arg method "$method" '{kind:$kind, method:$method}'
}

nse_env() {
  mkdir -p "$NSE_DIR/evidence"
  local trusted; trusted=$(nix store info --json 2>/dev/null | jq -r '.trusted // false')
  local wsl=false
  # `grep -q ... && wsl=true` as a bare command aborts a `set -e` script on any
  # machine that is not WSL. It has to be an `if`.
  if grep -qi microsoft /proc/version 2>/dev/null; then wsl=true; fi
  local os; os=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null)
  [ -n "$os" ] || os="unknown (no /etc/os-release PRETTY_NAME)"
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg nixVersion "$(nix --version)" \
    --arg kernel "$(uname -sr)" \
    --arg os "$os" \
    --arg system "$(nix eval --impure --raw --expr builtins.currentSystem)" \
    --arg storeDir "$(nse_store_dir)" \
    --argjson host "$(nse_detect_host)" \
    --argjson clientTrusted "$trusted" \
    --argjson wsl "$wsl" \
    --arg experimental "$(nix config show experimental-features)" \
    --arg substituters "$(nix config show substituters)" \
    --arg requireSigs "$(nix config show require-sigs)" \
    --arg sandbox "$(nix config show sandbox)" \
    --arg hashedMirrors "$(nix config show hashed-mirrors)" \
    --argjson provenance "$(nse_provenance)" \
    '{schemaVersion:3, kind:"environment", timestamp:$ts, provenance:$provenance,
      nixVersion:$nixVersion, system:$system, storeDir:$storeDir, kernel:$kernel, os:$os,
      host:$host, wsl2:$wsl, clientIsTrustedUser:$clientTrusted,
      nixConfig:{experimentalFeatures:$experimental, substituters:$substituters,
                 requireSigs:$requireSigs, sandbox:$sandbox, hashedMirrors:$hashedMirrors}}' \
    | nse_json_canonical | nse_write_file "$NSE_DIR/evidence/environment.json"

  jq -r '"NIX_VERSION=" + (.nixVersion|sub("^nix \\(Nix\\) ";"")),
         "SYSTEM=" + .system,
         "HOST=" + .host.kind,
         "EXECUTION_ENV=" + (if .wsl2 then "WSL2/" else "" end) + .os,
         "CLIENT_IS_TRUSTED_USER=" + (.clientIsTrustedUser|tostring)' \
    "$NSE_DIR/evidence/environment.json"
}

# The final report. Every section is conditional: a run that failed halfway is
# exactly when the report matters most, so a missing input prints NOT_RUN
# rather than aborting. Only a run with no evidence at all refuses.
nse_report() {
  local e=$NSE_DIR/evidence
  mkdir -p "$e"
  local m=$NSE_DIR/manifest.json
  local envj=$e/environment.json
  local vj=$e/verify.json tj=$e/trust.json oj=$e/origin-independence.json cj=$NSE_DIR/closure.json
  [ -f "$envj" ] || envj=""
  [ -f "$m" ]    || m=""
  [ -f "$vj" ]   || vj=""
  [ -f "$tj" ]   || tj=""
  [ -f "$oj" ]   || oj=""
  [ -f "$cj" ]   || cj=""

  if [ -z "$envj" ] && [ -z "$m" ]; then
    printf 'REPORT=INSUFFICIENT_STATE (no environment.json and no manifest.json under %s)\n' "$NSE_DIR" \
      | tee "$e/report.txt"
    return 1
  fi

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
    if [ -n "$envj" ]; then
      jq -r '"NIX_VERSION=" + (.nixVersion|sub("^nix \\(Nix\\) ";"")),
             "SYSTEM=" + .system,
             "HOST=" + .host.kind,
             "HOST_DETECTED_BY=" + .host.method,
             "EXECUTION_ENV=" + (if .wsl2 then "WSL2/" else "" end) + .os,
             "KERNEL=" + .kernel,
             "CLIENT_IS_TRUSTED_USER=" + (.clientIsTrustedUser|tostring),
             "AMBIENT_REQUIRE_SIGS=" + .nixConfig.requireSigs,
             "AMBIENT_HASHED_MIRRORS=" + (if .nixConfig.hashedMirrors == "" then "(unset)" else .nixConfig.hashedMirrors end),
             "TOOL_COMMIT=" + ((.provenance.toolRevision // "unknown")[0:12]) +
               " [" + (.provenance.revisionSource // "unknown") + "]" +
               (if .provenance.workingTreeDirty == true then " (WORKING TREE DIRTY)"
                elif .provenance.workingTreeDirty == false then " (clean)" else "" end)' \
        "$envj"
    else
      printf 'ENVIRONMENT=NOT_RUN\n'
    fi

    printf '\nDISCOVERY\n'
    if [ -n "$m" ]; then
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
             "DERIVATION_DOCUMENT=" + ((.derivationDocument.schema // "unrecorded")
                                       + " v" + ((.derivationDocument.version // "?")|tostring)
                                       + ", \(.derivationDocument.derivations // 0) derivations"),
             "IFD_DETECTED=" + .evalTimeFetches.ifd.status,
             "EVAL_TIME_FETCH_STATIC_ENUMERATION=" + .evalTimeFetches.staticEnumeration,
             "EVAL_TIME_FETCH_OFFLINE_PROBE=" + $evalProbe,
             "ESCROW_DISCOVERY_COMPLETE=" +
               (if (.counts.sourcesUnknown != 0 or .counts.sourcesUnsupported != 0
                    or .counts.flakeInputsUnknown != 0 or .evalTimeFetches.ifd.status != "absent")
                then "PARTIAL"
                # Zero fixed-output sources in a graph that builds something is
                # far likelier to be a discovery failure than a graph with no
                # sources -- it is exactly what a mis-read derivation document
                # produced, green, on Nix 2.24.9. Never PASS on it.
                elif .counts.sources == 0
                then "UNVERIFIED"
                elif ($evalProbe != "clean" or $isoMode != "namespaces")
                then "UNVERIFIED"
                else "PASS" end)' "$m"
      jq -r --arg evalProbe "$eval_probe" --arg isoMode "$isolation_mode" '
             if .counts.sources == 0
               then "  gap: NO fixed-output sources were discovered at all. For a graph that builds anything this is far more likely to be a failure to read the derivation document than a graph without sources; discovery read a \(.derivationDocument.schema // "?") document with \(.derivationDocument.derivations // 0) derivation(s)"
               else empty end,
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
    else
      printf 'DISCOVERY=NOT_RUN\n'
    fi

    printf '\nESCROW\n'
    if [ -n "$m" ]; then
      # `//` defaults throughout: a report must render evidence written by an
      # older version rather than die on a key that did not exist yet.
      jq -r '"GUARANTEE=" + (.guarantee // "unknown"),
             "BACKEND=" + (.escrow.backend // "unknown"),
             "STORE_URL=" + (.escrow.storeUrl // .escrow.url // "unknown"),
             "SUBSTITUTER_URL=" + (.escrow.substituterUrl // .escrow.url // "unknown"),
             "BINARY_REPLICA_URL=" + (.escrow.binaryReplicaUrl // "(none: the escrow holds the whole closure)"),
             (if .binaryTier == null then "APPROVED_BINARY_TIER=(none)" else
                "APPROVED_BINARY_TIER=" + .binaryTier.url end),
             (if .binaryTier == null then empty else
                "  TIER_CANDIDATES=\(.binaryTier.candidates)  TIER_CLAIMS=\(.binaryTier.present)  MATERIALISED=\(.binaryTier.materializedRoots)" end),
             (if .binaryTier == null then empty else
                "  CLAIMED_BUT_NOT_MATERIALISED=\(.binaryTier.claimedButNotMaterialized)  PROVIDED_TO_NOBODY=\(.binaryTier.notProvided)" end),
             "COMPRESSION=" + (.escrow.compression // "unknown"),
             "FLAKE_INPUTS_PRESERVED=\(.counts.flakeInputsPresent)/\(.counts.flakeInputs)",
             "SOURCES_REQUIRED_BY_PLAN=\(.counts.sourcesRequiredByPlan)",
             "SOURCES_PRESERVED=\(.counts.sourcesCoveredInEscrow)",
             "SOURCES_MISSING=\(.counts.sourcesMissing)",
             "SOURCES_DISCOVERED_NOT_REQUIRED_BY_PLAN=\(.counts.sourcesNotRequiredByPlan)"' "$m"
    else
      printf 'ESCROW=NOT_RUN\n'
    fi
    if [ -n "$cj" ]; then
      jq -r '"OBJECTS_REALISED=\(.paths|length)",
             "  IN_ESCROW=\(.escrowPaths|length)",
             "  IN_BINARY_REPLICA=\((.replicaPaths // [])|length)",
             "  PROVIDED_TO_NOBODY=\((.notProvidedPaths // [])|length) (the test instantiates or rebuilds these)"' "$cj"
    fi
    if [ -n "$vj" ]; then
      # Presence of an object and integrity of its NAR are different claims,
      # and conflating them is how an escrow gets reported as verified when it
      # is merely populated.
      jq -r '"OBJECTS_PRESENT=\(.presence.closurePaths - .presence.missing)/\(.presence.closurePaths)",
             "OBJECTS_NAR_VERIFIED=\(.narIntegrity.pathsChecked)/\(.presence.closurePaths)",
             "NAR_INTEGRITY_SCOPE=\(.narIntegrity.scope)",
             "NAR_INTEGRITY=\(.narIntegrity.status)",
             "CONTENT_IDENTITY_VERIFIED=\(.contentIdentity.verified)",
             "CONTENT_IDENTITY_MISMATCH=\(.contentIdentity.mismatched)",
             "ESCROW_VERIFY=\(.status)"' "$vj"
    else
      printf 'ESCROW_VERIFY=NOT_RUN\n'
    fi

    printf '\nTRUST\n'
    if [ -n "$tj" ]; then
      jq -r '"REQUIRE_SIGS_DURING_PROBE=\(.requireSigs)",
             "ESCROW_IS_SIGNED=\(.escrowIsSigned)",
             "ESCROW_KEY_IN_TRUSTED_PUBLIC_KEYS=\(.escrowKeyInTrustedKeys)",
             "SIGNING_KEYS_CREATED=\(.signingKeysCreated // 0)",
             "  content-addressed source, no trusted keys      -> \(.results.contentAddressedSource_noTrustedKeys)",
             "  content-addressed source, cache.nixos.org key  -> \(.results.contentAddressedSource_cacheNixosOrgKey)",
             "  input-addressed + signed, cache.nixos.org key  -> \(.results.signedInputAddressed_cacheNixosOrgKey)",
             "  input-addressed + signed, no trusted keys      -> \(.results.signedInputAddressed_noTrustedKeys)",
             "  input-addressed + unsigned, cache.nixos.org key-> \(.results.unsignedInputAddressed_cacheNixosOrgKey)",
             "SOURCE_SIGNATURE_REQUIRED=\(.conclusion.sourceSignatureRequired)"' "$tj"
    else
      printf 'TRUST_PROBE=NOT_RUN\n'
    fi
    if [ -n "$vj" ]; then
      jq -r '"ESCROW_OBJECTS_CONTENT_ADDRESSED=\(.trustComposition.contentAddressed)",
             "ESCROW_OBJECTS_SIGNATURE_ONLY=\(.trustComposition.signatureOnly)",
             "ESCROW_OBJECTS_UNSIGNED_INPUT_ADDRESSED=\(.trustComposition.unsignedInputAddressed)"' "$vj"
    fi
    if [ -n "$oj" ]; then
      jq -r '"TEST=" + (if .result=="PASS" then "PASS" else .result end)' "$oj"
    fi

    printf '\nNETWORK ACCEPTANCE\n'
    if [ -n "$oj" ]; then
      jq -r '"GUARANTEE=" + (.guarantee.name // "unknown"),
             "  proves: " + (.guarantee.proves // "(not recorded)"),
             "  does not prove: " + (.guarantee.doesNotProve // "(not recorded)"),
             "NETWORK_ISOLATION=" + .isolation,
             "ISOLATION_MODE=" + .isolationMode,
             "ISOLATION_SETUP=" + (.isolationSetup // "not recorded") +
               (if ((.isolationSetupFailures // [])|length) > 0
                then " (" + (.isolationSetupFailures|join(",")) + ")" else "" end),
             "NSS_ISOLATION=" + .nssIsolation,
             "ORIGIN_HOSTS_PROVEN_UNREACHABLE=" + ((.originHostsProvenUnreachable|join(",")) | if .=="" then "none" else . end),
             "ORIGIN_HOSTS_REACHABLE=" + ((.originHostsReachable|join(",")) | if .=="" then "none" else . end),
             "CACHE_NIXOS_ORG_ALLOWED=" + ([.connectivity[]|select(.host=="cache.nixos.org")|(.reachableByName or .reachableByAddress)]|first|tostring),
             "DURABLE_ESCROW=" + (.replaySource.durableEscrow // .escrowSubstituter // "not recorded"),
             "REPLAYED_FROM=" + (.replaySource.escrowUsedByTest // .escrowSubstituter // "not recorded") +
               " (" + (.replaySource.escrowMode // "direct") + ", \(.replaySource.escrowObjects // 0) objects)",
             (if (.replaySource.binaryReplicaUsedByTest // null) == null then empty else
                "BINARY_REPLICA_REPLAYED_FROM=" + .replaySource.binaryReplicaUsedByTest +
                " (" + .replaySource.binaryReplicaMode + ", \(.replaySource.binaryReplicaObjects // 0) objects)" end),
             "MODE_SUPPORTED=" + ((.modeSupported // true)|tostring),
             "REPLAY_OBJECTS_REQUESTED=\(.replaySource.objectsRequested // 0)",
             "  REACHABLE_BY_TEST=\(.replaySource.objectsReachableByTest // "not measured")  ARRIVED_AS_CLOSURE=\(.replaySource.objectsArrivedAsClosure // "not measured")",
             "  NOT_PROVIDED_BUT_REACHABLE=\(.replaySource.notProvidedReachableByTest // "not measured")",
             "SOURCES_IN_ESCROW_BEFORE_ISOLATION=\(.sourcesInEscrowBeforeIsolation // 0)/\(.sourcesRequired)",
             "SUBSTITUTERS_ONLY_ESCROW=" + (.substitutersOnlyEscrow|tostring),
             "SUBSTITUTERS_AS_CONFIGURED=" + ((.substitutersAsExpected // .substitutersOnlyEscrow)|tostring),
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

    if [ -n "${NSE_PIPELINE_STATUS:-}" ]; then
      printf '\nPIPELINE\n'
      printf 'ESCROW_PIPELINE=%s\n' "$NSE_PIPELINE_STATUS"
      [ -z "${NSE_PIPELINE_DETAIL:-}" ] || printf 'FAILED_STAGES=%s\n' "$NSE_PIPELINE_DETAIL"
    fi
  } | tee "$e/report.txt"
}

# The full pipeline, with one rule the v0.1 CLI got backwards: a FAILED run
# produces MORE evidence, not less. `set -e` plus a `nse_prove` that returns 1
# used to kill the process before the report was ever written -- so the report
# went missing exactly when someone needed it. The EXIT trap covers the
# nse_die paths too.
NSE_REPORT_EMITTED=0
nse_final_report() {
  local rc=$?
  trap - EXIT
  if [ "$NSE_REPORT_EMITTED" = 0 ]; then
    NSE_REPORT_EMITTED=1
    NSE_PIPELINE_STATUS=$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)
    export NSE_PIPELINE_STATUS
    nse_step "EVIDENCE REPORT (pipeline exit $rc)"
    nse_report || nse_warn "not enough state for a report; see $NSE_DIR"
  fi
  exit "$rc"
}

nse_escrow_pipeline() {
  local rc=0 failed=""
  trap nse_final_report EXIT

  nse_env
  nse_discover
  nse_preserve
  nse_verify      || { rc=$?; failed="$failed verify"; }
  nse_trust_probe || { rc=$?; failed="$failed trust-probe"; }
  nse_prove "$NSE_EXPECT" || { rc=$?; failed="$failed test-origin-independence"; }

  NSE_PIPELINE_DETAIL=${failed# }
  export NSE_PIPELINE_DETAIL
  return "$rc"
}
