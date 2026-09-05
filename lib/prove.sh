# shellcheck shell=bash
# PROVE: the origin-independence acceptance test.
#
# Two named guarantees, from the same harness (DESIGN.md §12):
#
#   ESCROW_REPLAY               the accepted build succeeds with every origin
#                               AND every third-party binary cache unreachable,
#                               using only the escrow.
#   SOURCE_ORIGIN_INDEPENDENCE  the accepted build succeeds with every source
#                               origin unreachable, given the approved binary
#                               tier is still available.
#
# Neither is FULL_AIRGAP_REBUILD -- see DESIGN.md §9.

# Hosts we actively probe and report on. Isolation is a network namespace with
# no route anywhere, so this list documents what we *checked*, not what we
# filtered: nothing is reachable, list or no list.
NSE_PROBE_HOSTS_DEFAULT="github.com codeload.github.com raw.githubusercontent.com gitlab.com ftp.gnu.org cache.nixos.org"

# Resolve the probe hosts *before* entering the namespace, while DNS still
# works, so the isolated run can also try to connect by address. Failing to
# resolve a name proves little; failing to reach a known address proves there
# is no route out. Hosts that do not resolve here are recorded as such.
nse_resolve_probe_hosts() {
  local h ip out=""
  for h in ${NSE_PROBE_HOSTS:-$NSE_PROBE_HOSTS_DEFAULT}; do
    ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}') || ip=""
    if [ -n "$ip" ]; then out="$out $h=$ip"; else out="$out $h=unresolved"; fi
  done
  printf '%s\n' "${out# }"
}

# What each guarantee claims, and what it does not. Written into the evidence
# so the report prints a recorded string rather than a hardcoded one.
nse_guarantee_name() {
  case $NSE_GUARANTEE in
    escrow-replay)              printf 'ESCROW_REPLAY\n' ;;
    source-origin-independence) printf 'SOURCE_ORIGIN_INDEPENDENCE\n' ;;
    *) nse_die "unknown guarantee '$NSE_GUARANTEE'" ;;
  esac
}
nse_guarantee_proves() {
  case $NSE_GUARANTEE in
    escrow-replay)
      printf 'the accepted build completes with every dependency origin and every third-party binary cache unreachable, from an empty store, using only the escrow\n' ;;
    source-origin-independence)
      printf 'the accepted build completes with every dependency origin unreachable, from an empty store, using the escrow for source material and a replica of the approved binary tier for prebuilt objects; anything the build actually needed that neither of those supplied had to be built inside the test\n' ;;
  esac
}
nse_guarantee_excludes() {
  case $NSE_GUARANTEE in
    escrow-replay)
      printf 'FULL_AIRGAP_REBUILD: the escrow holds prebuilt binaries that came from cache.nixos.org, so this does not show the graph can be rebuilt from source alone\n' ;;
    source-origin-independence)
      printf 'independence from the binary tier: the prebuilt objects came from a replica of an approved cache, so a loss of that cache is NOT covered. That claim is ESCROW_REPLAY\n' ;;
  esac
}

# Materialise what the acceptance test will replay from.
#
# The test runs with no route to anything, so a REMOTE escrow -- S3, Attic, an
# HTTPS cache -- is exactly as unreachable inside the namespace as GitHub is.
# Pointing `substituters` at one and calling a green build a proof of anything
# would be a lie about which store served the bytes.
#
# So a non-local store is copied into a local proof replica BEFORE isolation,
# and the test replays from that. What that buys, precisely:
#
#   before isolation  the durable store was asked for every object in the set
#                     and produced it
#   after isolation   that exact set replays the build with no network
#
# What it does not buy is any claim about the durable store being reachable
# during a blackout. That store's availability is its own problem, not
# something this test can or should establish.
#
# Sets NSE_PROOF_URL / NSE_PROOF_MODE / NSE_PROOF_N.
nse_proof_source() {
  local label=$1 url=$2 setfile=$3
  local n; n=$(wc -l < "$setfile")
  if nse_url_is_file "$url"; then
    NSE_PROOF_URL=$url; NSE_PROOF_MODE=direct; NSE_PROOF_N=$n
    return 0
  fi
  local dir=$NSE_PROOF_REPLICA/$label
  nse_rm_store "$dir"; mkdir -p "$dir"
  nse_log "proof replica ($label): materialising $n objects from $url -> file://$dir"
  nse_nix_batched "$setfile" copy --from "$url" \
    --to "file://$dir?compression=${NSE_COMPRESSION:-zstd}" --no-check-sigs \
    || nse_die "cannot materialise the proof replica for '$label' from '$url'"
  # Not a command substitution: that swallowed the observation status, so a
  # proof replica that could not be read looked like one holding 0 objects.
  local got
  nse_observe_present "file://$dir" "$setfile" "$dir.present.txt" \
    "what the proof replica holds after materialisation"
  got=$(wc -l < "$dir.present.txt")
  [ "$got" -eq "$n" ] \
    || nse_die "proof replica ($label) holds $got of $n objects after materialisation from '$url'"
  NSE_PROOF_URL="file://$dir"; NSE_PROOF_MODE=materialised; NSE_PROOF_N=$n
  return 0
}

nse_prove() {
  local expect=${1:-pass}
  local manifest=$NSE_DIR/manifest.json
  local work=$NSE_DIR/work
  local teststore=$work/test-store
  local testhome=$work/test-home
  [ -f "$manifest" ] || nse_die "no manifest.json; run 'nix-source-escrow preserve' first"
  [ -f "$NSE_DIR/closure.json" ] \
    || nse_die "no closure.json; run 'nix-source-escrow preserve' first"
  mkdir -p "$work" "$NSE_DIR/evidence"

  nse_step "$(nse_guarantee_name) acceptance test (expect=$expect)"
  nse_require_cmd unshare ip curl getent awk

  # ---- clean, controlled state --------------------------------------------
  # A green result must not be obtainable because a source happened to be lying
  # around. The store starts empty and HOME is fresh, so Nix has neither a warm
  # fetcher cache nor a warm eval cache to fall back on.
  nse_rm_store "$teststore"
  rm -rf "$testhome"
  mkdir -p "$teststore" "$testhome"
  [ -z "$(ls -A "$teststore" 2>/dev/null)" ] \
    || nse_die "test store $teststore is not empty after wipe; refusing to run"
  nse_log "clean test store: $teststore (empty)"
  nse_log "clean fetcher/eval cache: HOME=$testhome"

  rm -f "$work/prove-result.json"

  # ---- precondition: is this claim available at all? ----------------------
  # MODE_UNSUPPORTED is for a claim this harness cannot model on these inputs --
  # not for "one particular cache does not have one particular path", which is
  # a data condition the acceptance build is perfectly able to resolve by
  # building the thing. The real case is a mismatch: the escrow was PRESERVED
  # for one guarantee and is being PROVEN against another, so the path sets on
  # disk do not correspond to the claim being made and no build outcome would
  # mean what the verdict says.
  local mode_supported=true mode_reason=""
  local preserved_for; preserved_for=$(jq -r '.guarantee // "unknown"' "$manifest")
  if [ "$preserved_for" != "$NSE_GUARANTEE" ]; then
    mode_supported=false
    mode_reason="the escrow was preserved for '$preserved_for' but this run asks for a '$NSE_GUARANTEE' verdict; the escrowed and replicated path sets do not correspond to the claim, so no build outcome could establish it. Re-run preserve with --guarantee $NSE_GUARANTEE."
  fi

  # ---- precondition: does the ESCROW itself hold the sources? -------------
  # Asked of the durable escrow, before isolation, and recorded separately from
  # the post-build presence check. Under SOURCE_ORIGIN_INDEPENDENCE a second
  # substituter is configured, so "the store was empty and nothing was
  # reachable, therefore it came from the escrow" no longer follows on its own
  # -- an approved cache may well carry source FODs too. This is the claim that
  # does follow, and it does not depend on anyone having run `verify` first.
  jq -r '.sources[] | select(.plan.requiredByPlan) | .storePath' "$manifest" \
    | LC_ALL=C sort -u > "$work/prove-required-sources.txt"
  nse_observe_present "$NSE_SUBSTITUTER_URL" \
    "$work/prove-required-sources.txt" "$work/prove-sources-in-escrow.txt" \
    "whether the escrow holds every plan-required source"
  local sources_required sources_in_escrow
  sources_required=$(wc -l < "$work/prove-required-sources.txt")
  sources_in_escrow=$(wc -l < "$work/prove-sources-in-escrow.txt")
  nse_log "escrow holds $sources_in_escrow/$sources_required plan-required sources (checked before isolation, against $NSE_SUBSTITUTER_URL)"

  # ---- what the test replays from -----------------------------------------
  local closure=$NSE_DIR/closure.json
  jq -r '(.escrowPaths // .paths)[]' "$closure" | LC_ALL=C sort -u > "$work/prove-escrow-set.txt"
  jq -r '(.replicaPaths // [])[]' "$closure"    | LC_ALL=C sort -u > "$work/prove-replica-set.txt"

  nse_proof_source escrow "$NSE_SUBSTITUTER_URL" "$work/prove-escrow-set.txt"
  local escrow_proof=$NSE_PROOF_URL escrow_proof_mode=$NSE_PROOF_MODE escrow_proof_n=$NSE_PROOF_N

  local substituters=$escrow_proof
  local replica_proof="" replica_proof_mode=none replica_proof_n=0
  if [ "$NSE_GUARANTEE" = source-origin-independence ]; then
    nse_proof_source replica "$NSE_REPLICA_URL" "$work/prove-replica-set.txt"
    replica_proof=$NSE_PROOF_URL; replica_proof_mode=$NSE_PROOF_MODE; replica_proof_n=$NSE_PROOF_N
    substituters="$escrow_proof $replica_proof"
  fi

  # ---- audit what the test can actually reach ------------------------------
  # `nix copy` copies CLOSURES, so "we asked for 53 roots" is not "53 objects
  # arrived". Measure the stores the test will use, rather than reporting the
  # size of the request as though it were the size of the result.
  #
  # The check that matters: nothing from notProvidedPaths may be reachable. The
  # claim is not that every one of them WAS built -- the build may never need a
  # given path, and forcing it to would be busywork -- it is that none of them
  # could have been obtained instead of built. A closure copy that quietly put
  # one next to the build breaks exactly that, so it is measured.
  jq -r '(.notProvidedPaths // [])[]' "$closure" | LC_ALL=C sort -u \
    > "$work/prove-not-provided.txt"
  LC_ALL=C sort -u "$work/prove-escrow-set.txt" "$work/prove-replica-set.txt" \
    > "$work/prove-requested.txt"
  : > "$work/prove-replay-objects.txt"
  local audited=true pair url
  for pair in "escrow=$escrow_proof" "replica=$replica_proof"; do
    url=${pair#*=}
    [ -n "$url" ] || continue
    if nse_url_is_file "$url"; then
      nse_store_list "$url" >> "$work/prove-replay-objects.txt"
    else
      audited=false
    fi
  done
  LC_ALL=C sort -u -o "$work/prove-replay-objects.txt" "$work/prove-replay-objects.txt"

  local replay_actual=null replay_unrequested=null replay_leak=null replay_leak_n=0
  if [ "$audited" = true ]; then
    replay_actual=$(wc -l < "$work/prove-replay-objects.txt")
    replay_unrequested=$(LC_ALL=C comm -23 "$work/prove-replay-objects.txt" "$work/prove-requested.txt" | wc -l)
    LC_ALL=C comm -12 "$work/prove-replay-objects.txt" "$work/prove-not-provided.txt" \
      > "$work/prove-replay-leak.txt"
    replay_leak_n=$(wc -l < "$work/prove-replay-leak.txt")
    replay_leak=$replay_leak_n
    nse_log "replay audit: $replay_actual objects reachable ($(wc -l < "$work/prove-requested.txt") requested, $replay_unrequested arrived as closure), $replay_leak_n of them were supposed to be provided to nobody"
  else
    nse_warn "replay audit: a substituter is not a file:// store, so what the test can reach was not measured"
  fi

  local envf=$work/prove-env.sh
  # The secret-bearing fragment, if any, in a file only this user can read, and
  # only for as long as the run needs it.
  local extra_cfg_file=""
  if [ -n "${NSE_EXTRA_NIX_CONFIG:-}" ]; then
    extra_cfg_file=$work/prove-extra-nix-config
    ( umask 077; printf '%s\n' "$NSE_EXTRA_NIX_CONFIG" > "$extra_cfg_file" )
    chmod 0600 "$extra_cfg_file"
    # Removed however this run ends, including on nse_die.
    # shellcheck disable=SC2064  # expand the path now, not at trap time
    trap "rm -f '$extra_cfg_file'" EXIT
  fi
  {
    printf 'NSE_SUBSTITUTERS=%q\n' "$substituters"
    printf 'NSE_ESCROW_SUBSTITUTER=%q\n' "$escrow_proof"
    printf 'NSE_DURABLE_ESCROW=%q\n' "$NSE_SUBSTITUTER_URL"
    printf 'NSE_SOURCES_REQUIRED=%q\n' "$sources_required"
    printf 'NSE_SOURCES_IN_ESCROW=%q\n' "$sources_in_escrow"
    printf 'NSE_MODE_SUPPORTED=%q\n' "$mode_supported"
    printf 'NSE_REPLAY_LEAK=%q\n' "$replay_leak_n"
    printf 'NSE_REPLAY_AUDITED=%q\n' "$audited"
    printf 'NSE_MODE_REASON=%q\n' "$mode_reason"
    printf 'NSE_TESTSTORE=%q\n'    "$teststore"
    printf 'NSE_TESTHOME=%q\n'     "$testhome"
    printf 'NSE_INSTALLABLE=%q\n'  "$NSE_INSTALLABLE"
    printf 'NSE_MANIFEST=%q\n'     "$manifest"
    printf 'NSE_WORK=%q\n'         "$work"
    printf 'NSE_PROBE_IPS=%q\n'    "$(nse_resolve_probe_hosts)"
    printf 'NSE_PWD=%q\n'          "$PWD"
    printf "NSE_TRUSTED_KEYS=%q\n" "${NSE_TRUSTED_KEYS:-cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=}"
    # NOT the value. --extra-nix-config is where a netrc line, a bearer token or
    # an S3 secret arrives, and this file lives in work/, which the CI job
    # uploads as an artifact. Serialising a credential into a build artifact to
    # make a shell variable convenient is not a trade worth making. The evidence
    # records only that something was supplied; the value reaches the namespace
    # through a 0600 file that is removed on the way out.
    printf "NSE_EXTRA_NIX_CONFIG_PRESENT=%q\n" \
      "$([ -n "${NSE_EXTRA_NIX_CONFIG:-}" ] && echo yes || echo no)"
    printf "NSE_EXTRA_NIX_CONFIG_FILE=%q\n" "$extra_cfg_file"
    printf "NSE_GUARANTEE_NAME=%q\n" "$(nse_guarantee_name)"
    printf "NSE_ISOLATION_MODE=%q\n" "$([ "${NSE_NO_ISOLATION:-0}" = 1 ] && echo none || echo namespaces)"
  } > "$envf"

  nse_write_inner_script "$work/prove-inner.sh"

  local rc=0 isolation
  if [ "${NSE_NO_ISOLATION:-0}" = 1 ]; then
    nse_warn "running WITHOUT network isolation (--no-isolation): this is a control run, not an acceptance result"
    isolation="none (control run)"
    bash "$work/prove-inner.sh" "$envf" || rc=$?
  else
    isolation="user+network+mount namespace (unshare -Ur --net --mount)"
    unshare -Ur --net --mount -- bash "$work/prove-inner.sh" "$envf" || rc=$?
  fi

  [ -f "$work/prove-result.json" ] \
    || nse_die "isolated runner produced no result file (exit $rc); see $work/prove-build.log"

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg isolation "$isolation" \
    --arg expect "$expect" \
    --arg gName "$(nse_guarantee_name)" \
    --arg gProves "$(nse_guarantee_proves)" \
    --arg gExcludes "$(nse_guarantee_excludes)" \
    --argjson runnerExit "$rc" \
    --argjson provenance "$(nse_provenance)" \
    --arg durableEscrow "$NSE_SUBSTITUTER_URL" \
    --arg escrowProof "$escrow_proof" --arg escrowProofMode "$escrow_proof_mode" \
    --arg replicaProof "$replica_proof" --arg replicaProofMode "$replica_proof_mode" \
    --argjson escrowProofObjects "$escrow_proof_n" \
    --argjson replicaProofObjects "$replica_proof_n" \
    --argjson replayActual "$replay_actual" \
    --argjson replayUnrequested "$replay_unrequested" \
    --argjson replayLeak "$replay_leak" \
    --arg binaryTier "$([ "$NSE_GUARANTEE" = source-origin-independence ] && printf '%s' "$NSE_BINARY_TIER")" \
    --slurpfile r "$work/prove-result.json" \
    '$r[0] + {schemaVersion:3, kind:"origin-independence", timestamp:$ts,
              isolation:$isolation, expectation:$expect, runnerExit:$runnerExit,
              provenance:$provenance,
              guarantee:{name:$gName, proves:$gProves, doesNotProve:$gExcludes},
              replaySource:{
                durableEscrow:$durableEscrow,
                escrowUsedByTest:$escrowProof, escrowMode:$escrowProofMode,
                escrowObjects:$escrowProofObjects,
                binaryReplicaObjects:$replicaProofObjects,
                binaryTier:(if $binaryTier=="" then null else $binaryTier end),
                binaryReplicaUsedByTest:(if $replicaProof=="" then null else $replicaProof end),
                binaryReplicaMode:$replicaProofMode,
                objectsRequested:($escrowProofObjects + $replicaProofObjects),
                objectsReachableByTest:$replayActual,
                objectsArrivedAsClosure:$replayUnrequested,
                notProvidedReachableByTest:$replayLeak}}' \
    | nse_json_canonical | nse_write_file "$NSE_DIR/evidence/origin-independence.json"

  nse_prove_report "$NSE_DIR/evidence/origin-independence.json" "$expect"
}

# Remove a Nix store directory. Store paths are mode 0555, so a plain rm fails.
nse_rm_store() {
  local d=$1
  [ -e "$d" ] || return 0
  chmod -R u+w "$d" 2>/dev/null || :
  rm -rf "$d" || nse_die "cannot remove $d"
}

nse_prove_report() {
  local f=$1 expect=$2
  local result; result=$(jq -r '.result' "$f")

  # Report only what was demonstrated. "PROVEN_UNREACHABLE" lists hosts shown
  # unreachable by both probes -- never the hosts we merely intended to block.
  jq -r '
    "GUARANTEE=" + (.guarantee.name // "unknown"),
    "NETWORK_ISOLATION=" + .isolation,
    "ISOLATION_MODE=" + .isolationMode,
    "ISOLATION_SETUP=" + (.isolationSetup // "not recorded"),
    "NSS_ISOLATION=" + .nssIsolation,
    "ORIGIN_HOSTS_PROVEN_UNREACHABLE=" + ((.originHostsProvenUnreachable|join(",")) | if .=="" then "none" else . end),
    "ORIGIN_HOSTS_REACHABLE=" + ((.originHostsReachable|join(",")) | if .=="" then "none" else . end),
    "CACHE_NIXOS_ORG_ALLOWED=" + ([.connectivity[]|select(.host=="cache.nixos.org")|(.reachableByName or .reachableByAddress)]|first|tostring),
    "SUBSTITUTERS_AS_CONFIGURED=" + (.substitutersAsExpected|tostring),
    "MODE_SUPPORTED=" + ((.modeSupported // true)|tostring),
    "REPLAY_SOURCE=" + .replaySource.escrowUsedByTest + " (" + .replaySource.escrowMode + " from " + .replaySource.durableEscrow + ")",
    "REPLAY_OBJECTS_REQUESTED=\(.replaySource.objectsRequested)  REACHABLE=\(.replaySource.objectsReachableByTest // "not measured")  AS_CLOSURE=\(.replaySource.objectsArrivedAsClosure // "not measured")",
    "NOT_PROVIDED_REACHABLE=\(.replaySource.notProvidedReachableByTest // "not measured")",
    "OFFLINE_EVAL_PROBE=" + .offlineEvalProbe,
    "SOURCES_IN_ESCROW_BEFORE_ISOLATION=\(.sourcesInEscrowBeforeIsolation)/\(.sourcesRequired)",
    "REQUIRED_SOURCES_RESTORED=\(.sourcesRestored)/\(.sourcesRequired)",
    "HTTP_FETCHES_IN_BUILD_LOG=\(.httpFetchesInBuildLog)",
    "OUTPUT_PATH_MATCHES_MANIFEST=" + (.outputMatches|tostring)
  ' "$f" >&2

  printf 'ORIGIN_INDEPENDENCE=%s\n' "$result"
  [ "$result" = PASS ] || jq -r '"REASON=" + (.reason // "unspecified")' "$f"

  case $expect in
    pass)
      [ "$result" = PASS ] || return 1 ;;
    fail)
      # A negative control must fail *for the right reason*. NOT_ISOLATED and
      # HARNESS_ERROR are broken harnesses, not demonstrations that the escrow
      # was incomplete.
      if [ "$result" = PASS ]; then
        printf 'NEGATIVE_CONTROL=FAIL (the build succeeded although the escrow was incomplete)\n'
        return 1
      fi
      if [ "$result" != FAIL ]; then
        printf 'NEGATIVE_CONTROL=FAIL (expected a build failure, got %s)\n' "$result"
        return 1
      fi
      printf 'NEGATIVE_CONTROL=PASS (the build correctly failed with an incomplete escrow)\n' ;;
    *) nse_die "unknown expectation '$expect'" ;;
  esac
}

nse_write_inner_script() {
  cat > "$1" <<'INNER'
#!/usr/bin/env bash
# Runs inside the isolated namespaces. Everything it touches is either the
# escrow (a substituter) or a store it created itself.
set -uo pipefail
# shellcheck disable=SC1090
. "$1"

: > "$NSE_WORK/prove-setup.log"

# Every setup operation is checked. A harness that half-applied its isolation
# must say so: an unchecked `ip link add` that fails turns into a build failure
# three steps later, attributed to the escrow, which is a lie.
isolation_setup=ok
setup_failures=""
require_setup() {
  local label=$1; shift
  if "$@" >>"$NSE_WORK/prove-setup.log" 2>&1; then return 0; fi
  printf 'SETUP FAILED: %s (%s)\n' "$label" "$*" >> "$NSE_WORK/prove-setup.log"
  setup_failures="${setup_failures:+$setup_failures,}$label"
  isolation_setup=failed
  return 1
}

# ---- 1. mount isolation --------------------------------------------------
# glibc NSS reaches nscd/nsncd over a *unix socket*, which a network namespace
# does not isolate; without this, name resolution inside the namespace is still
# answered by the host. It cannot move bytes, but we would rather not have to
# argue about that in the evidence. NSS isolation is graded (full/partial), not
# fatal -- the by-address probes are what carry the argument.
nss_isolation=full
if [ "$NSE_ISOLATION_MODE" = none ]; then
  nss_isolation=none
  isolation_setup=skipped
else
  mount --make-rprivate / 2>/dev/null || nss_isolation=partial
  for d in /run/nscd /var/run/nscd; do
    if [ -d "$d" ]; then
      mount -t tmpfs -o size=1k none "$d" 2>/dev/null || nss_isolation=partial
    fi
  done
  : > /tmp/nse-empty-resolv.conf
  mount --bind /tmp/nse-empty-resolv.conf /etc/resolv.conf 2>/dev/null || nss_isolation=partial

  # ---- 2. network isolation ----------------------------------------------
  # Loopback, and nothing else. There was a dummy route-to-nowhere device here,
  # working around Nix disabling *all* substituters -- local file:// ones
  # included -- when it decides the machine is offline. `substitute = true` in
  # NIX_CONFIG below is the explicit override that makes that decision moot
  # (src/nix/main.cc), and E1/E3 confirmed it on both Nix versions in every run
  # from 6 to 11 with a green baseline each time. Removed in full rather than
  # left switched off: see DESIGN.md §8 and §17a.
  require_setup lo-up ip link set lo up
fi

# ---- 3. record what is actually reachable --------------------------------
# Two probes per host: by name, and by the address resolved before we entered
# the namespace. The second one is the one that matters, because it cannot be
# explained away as "you only broke DNS".
: > "$NSE_WORK/prove-connectivity.jsonl"
for pair in $NSE_PROBE_IPS; do
  h=${pair%%=*}
  ip=${pair#*=}
  role=origin
  [ "$h" = cache.nixos.org ] && role=binary-cache

  err_name=$(curl -sS -m 6 --connect-timeout 5 -o /dev/null "https://$h/" 2>&1)
  rc_name=$?
  [ "$rc_name" -eq 0 ] && reach_name=true || reach_name=false

  if [ "$ip" = unresolved ]; then
    reach_addr=false; rc_addr=-1; err_addr="host did not resolve outside the namespace either"
  else
    err_addr=$(curl -sS -m 6 --connect-timeout 5 -o /dev/null \
                 --resolve "$h:443:$ip" "https://$h/" 2>&1)
    rc_addr=$?
    [ "$rc_addr" -eq 0 ] && reach_addr=true || reach_addr=false
  fi

  dns=$(getent hosts "$h" 2>/dev/null | awk 'NR==1{print $1}') || dns=""

  jq -n --arg host "$h" --arg role "$role" --arg ip "$ip" \
        --argjson reachableByName "$reach_name" --argjson curlExitByName "$rc_name" \
        --arg errorByName "$err_name" \
        --argjson reachableByAddress "$reach_addr" --argjson curlExitByAddress "$rc_addr" \
        --arg errorByAddress "$err_addr" \
        --arg dns "${dns:-}" \
     '{host:$host, role:$role, preResolvedAddress:$ip,
       reachableByName:$reachableByName, curlExitByName:$curlExitByName, errorByName:$errorByName,
       reachableByAddress:$reachableByAddress, curlExitByAddress:$curlExitByAddress, errorByAddress:$errorByAddress,
       dnsResolvedInsideTo:(if $dns=="" then null else $dns end)}' \
     >> "$NSE_WORK/prove-connectivity.jsonl"
done

jq -s '.' "$NSE_WORK/prove-connectivity.jsonl" > "$NSE_WORK/prove-connectivity.json"
reachable_origins=$(jq -r '[.[]|select(.role=="origin" and (.reachableByName or .reachableByAddress))]|length' \
                      "$NSE_WORK/prove-connectivity.json")
unresolved_origins=$(jq -r '[.[]|select(.role=="origin" and .preResolvedAddress=="unresolved")]|length' \
                      "$NSE_WORK/prove-connectivity.json")

export HOME="$NSE_TESTHOME"
export XDG_CACHE_HOME="$NSE_TESTHOME/.cache"

# If a config fragment was supplied, it must ARRIVE. A carrier file that cannot
# be read here would drop the operator's credential silently, and the run would
# then fail against their authenticated tier with an error pointing at the tier
# rather than at us -- or, worse, pass against a store that never needed it. A
# fragment that was supplied and did not arrive is a harness error, not a
# degraded run. The message names the file, never its contents.
nse_extra_cfg=""
if [ "${NSE_EXTRA_NIX_CONFIG_PRESENT:-no}" = yes ]; then
  if [ -n "${NSE_EXTRA_NIX_CONFIG_FILE:-}" ] && [ -r "$NSE_EXTRA_NIX_CONFIG_FILE" ]; then
    nse_extra_cfg=$(cat "$NSE_EXTRA_NIX_CONFIG_FILE")
  else
    printf 'prove: a nix config fragment was supplied but its carrier file %s is not readable inside the namespace; refusing to run without it\n' \
      "${NSE_EXTRA_NIX_CONFIG_FILE:-<unset>}" >&2
    exit 91
  fi
fi
# `substitute = true` is set on purpose and is load-bearing: Nix only
# auto-disables substitution when that setting is NOT an explicit override.
export NIX_CONFIG="experimental-features = nix-command flakes
substitute = true
substituters = $NSE_SUBSTITUTERS
trusted-substituters =
trusted-public-keys = $NSE_TRUSTED_KEYS
require-sigs = true
flake-registry =
warn-dirty = false
build-users-group =
require-drop-supplementary-groups = false
$nse_extra_cfg
"

cd "$NSE_PWD" || { printf 'prove: cannot cd to %s\n' "$NSE_PWD" >&2; exit 90; }

# The configured substituters must be exactly the ones this guarantee allows.
# If anything else were configured, a green build would not tell us where the
# sources came from. Compared as a set, so ordering is not a failure.
effective_substituters=$(nix config show substituters 2>/dev/null | tr -s ' ')
norm() { printf '%s\n' "$1" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | paste -sd' ' -; }
if [ "$(norm "$effective_substituters")" = "$(norm "$NSE_SUBSTITUTERS")" ]; then
  substituters_ok=true
else
  substituters_ok=false
fi

reason=""
step=""

# ---- 3a. preconditions established OUTSIDE isolation ---------------------
# Two facts the harness measured before entering the namespace, because that is
# where the durable escrow is reachable at all:
#
#   NSE_SOURCES_IN_ESCROW / NSE_SOURCES_REQUIRED
#       how many plan-required sources the durable escrow actually holds
#   NSE_MODE_SUPPORTED
#       whether the guarantee under test is available at all -- under
#       SOURCE_ORIGIN_INDEPENDENCE it is not, if the approved binary tier
#       cannot supply an object this build does not produce for itself
#
# When the mode is unsupported the build is skipped entirely: no build outcome
# can establish a claim that is unavailable, and running one would only produce
# a failure that reads as an accusation against the escrow.
if [ "$NSE_MODE_SUPPORTED" != true ]; then
  step=mode-precondition
fi

# ---- 4. flake input material ---------------------------------------------
# Nothing happens here, on purpose, and that is the whole point.
#
# There used to be a pre-copy of the locked input paths out of the escrow into
# the test store. It proved that WE could put the inputs there, not that a
# stock consumer gets them -- an easier question than the one being asked.
# Input::getAccessorUnchecked computes the store path from the lock's narHash
# and calls ensurePath, so a configured substituter is enough; E2 and E3
# confirmed it on both Nix versions in every run from 6 to 11. Deleted rather
# than demoted, because a diagnostic nobody runs is dead code. DESIGN.md §8a.
# t11 asserts the property that actually matters: every flake input, transitive
# ones included, served from the escrow with its origin unreachable.

# ---- 5. offline evaluation probe -----------------------------------------
# This is the ONLY thing that can cover eval-time fetches. builtins.fetchTarball
# / fetchGit / fetchurl with a pinned hash never appear in the derivation graph,
# so discovery cannot enumerate them. Here the evaluation runs with no network
# and an empty XDG_CACHE_HOME, so any such fetch has nowhere to come from and
# this probe fails instead of the gap passing silently.
eval_rc=1
if [ -z "$reason" ] && [ "$NSE_MODE_SUPPORTED" = true ]; then
  step=offline-eval-probe
  nix path-info --derivation --store "$NSE_TESTSTORE" "$NSE_INSTALLABLE" \
    > "$NSE_WORK/prove-eval.log" 2>&1
  eval_rc=$?
  [ "$eval_rc" -eq 0 ] || reason="evaluation failed offline; an eval-time fetch or flake input is not covered by the escrow (see prove-eval.log)"
fi

# ---- 6. the build --------------------------------------------------------
built=""
build_rc=1
if [ -z "$reason" ] && [ "$NSE_MODE_SUPPORTED" = true ]; then
  step=build
  built=$(nix build --store "$NSE_TESTSTORE" "$NSE_INSTALLABLE" --no-link --print-out-paths \
          2> "$NSE_WORK/prove-build.log")
  build_rc=$?
  [ "$build_rc" -eq 0 ] || reason="build failed under origin blackout (see prove-build.log)"
fi

# ---- 7. are the required sources in the test store? ----------------------
# The store started empty and nothing was reachable, so a valid source path here
# came from one of the configured substituters. Under ESCROW_REPLAY that is the
# escrow and nothing else. Under SOURCE_ORIGIN_INDEPENDENCE a second one is
# configured, and an approved cache can perfectly well carry source FODs too --
# so this check alone does NOT attribute the source to the escrow. The
# attribution comes from NSE_SOURCES_IN_ESCROW, measured against the durable
# escrow before isolation and required to be complete by the verdict below.
#
# One query for the whole set; the per-path loop is only the fallback for a
# batch Nix refuses.
step=post-checks

# How many of these paths does the test store actually hold?
#
# `nix path-info --json` answers `"<path>": null` for a path it does not have
# and exits 0. This function used to count `keys | length`, so an absent path
# was counted as present -- the same P0 that made the binary tier claim 227 of
# 227 in run 6, still live in the post-check that decides t07.7. It happens to
# have been reporting 4/4 correctly, because the paths really were there; it
# would have reported 4/4 just as confidently if they had not been.
present_paths() {
  jq -r 'if type=="array"
         then (.[] | select(. != null and (.path? != null)) | .path)
         else (to_entries[] | select(.value != null) | .key) end'
}

# One query for the whole set; the per-path loop is only the fallback for a
# batch Nix refuses outright. Prints the paths rather than counting them, so a
# caller can say WHICH ones: "2 of 4" is a number, and the two names are the
# finding.
present_in_teststore() {
  local -a paths=("$@")
  local answer p
  [ "${#paths[@]}" -gt 0 ] || return 0
  if answer=$(nix path-info --store "$NSE_TESTSTORE" --json "${paths[@]}" 2>/dev/null); then
    printf '%s\n' "$answer" | present_paths
    return 0
  fi
  for p in "${paths[@]}"; do
    if nix path-info --store "$NSE_TESTSTORE" "$p" >/dev/null 2>&1; then printf '%s\n' "$p"; fi
  done
}

mapfile -t required_paths < <(jq -r '.sources[] | select(.plan.requiredByPlan) | .storePath' "$NSE_MANIFEST")
required=${#required_paths[@]}
restored=$(present_in_teststore "${required_paths[@]+"${required_paths[@]}"}" | grep -c . || :)

# The flake inputs, in the store the isolated build actually used.
#
# This is the measurement t07.9 always claimed to make and never did: it read
# `restoreExit`, the exit code of a `nix copy` that the default path never ran,
# so it asserted 0 == 0 about a command that did not execute. The manual copy
# is gone (DESIGN.md §8a); the property it was supposed to stand for is real
# and is measured here.
#
# The first honest version of it over-claimed in the other direction, and the
# run said so: 2 of 4. So the NAMES are recorded, not just the count.
#
# READ THIS FIELD PRECISELY. It says which locked inputs were PRESENT in the
# test store after a build that succeeded with every origin unreachable. It
# does NOT say those inputs are NECESSARY, and it does not say the absent two
# are unnecessary in general -- only that this evaluation completed without
# them. Necessity is a different experiment: remove one surviving input and
# require a pre-defined red trace. Nobody has run that.
mapfile -t input_paths < <(jq -r '.flakeInputs[] | select(.storePath != null) | .storePath' "$NSE_MANIFEST")
inputs_required=${#input_paths[@]}
present_in_teststore "${input_paths[@]+"${input_paths[@]}"}" > "$NSE_WORK/prove-inputs-present.txt"
inputs_present=$(grep -c . "$NSE_WORK/prove-inputs-present.txt" || :)
inputs_present_names=$(jq -r --rawfile present "$NSE_WORK/prove-inputs-present.txt" '
  ($present | split("\n") | map(select(length > 0))) as $p
  | [ .flakeInputs[] | select(.storePath != null and (.storePath | IN($p[]))) | .name ]
  | sort | join(",")' "$NSE_MANIFEST")

expected_out=$(jq -r '.expectedOutputs[0] // ""' "$NSE_MANIFEST")

net_lines=0
if [ -f "$NSE_WORK/prove-build.log" ]; then
  net_lines=$(grep -cE "from .(https?)://" "$NSE_WORK/prove-build.log") || net_lines=0
fi

out_matches=false
[ -n "$built" ] && [ "$built" = "$expected_out" ] && out_matches=true

# ---- 8. verdict ----------------------------------------------------------
# Order matters. The environmental preconditions are checked BEFORE the build
# outcome, because a build that succeeds while GitHub is reachable proves
# nothing at all -- and reporting it as PASS is exactly the failure mode this
# ordering exists to prevent. A half-applied harness is its own verdict, so it
# can never be mistaken for evidence about the escrow.
result=FAIL
if [ "$NSE_ISOLATION_MODE" = none ]; then
  result=NOT_ISOLATED
  reason="network isolation was disabled (--no-isolation); this is a control run and can never establish origin independence"
elif [ "$reachable_origins" -ne 0 ]; then
  result=FAIL
  reason="$reachable_origins origin host(s) were still reachable from inside the test environment"
elif [ "$unresolved_origins" -ne 0 ]; then
  result=FAIL
  reason="$unresolved_origins origin host(s) could not be resolved before isolation, so their unreachability is unproven"
elif [ "$NSE_MODE_SUPPORTED" != true ]; then
  # Not a failure of the escrow and not a failure of the harness: the claim
  # itself is unavailable on these inputs. It can never be PASS, and
  # --expect-fail must not accept it as a negative control either.
  result=MODE_UNSUPPORTED
  reason="$NSE_MODE_REASON"
elif [ "$isolation_setup" = failed ]; then
  # Measured reachability comes first because it is the more specific finding:
  # a reachable origin invalidates the run whatever the cause. Reaching HERE
  # means nothing was reachable *and* the harness was half-applied -- which is
  # the case that used to be indistinguishable from an incomplete escrow, and
  # got reported as "build failed under origin blackout".
  result=HARNESS_ERROR
  reason="isolation setup failed ($setup_failures); the environment was not the one this test claims to run in, so no conclusion about the escrow is available (see prove-setup.log)"
elif [ "$substituters_ok" != true ]; then
  result=FAIL
  reason="substituters were '$effective_substituters', expected exactly '$NSE_SUBSTITUTERS'"
elif [ "${NSE_REPLAY_AUDITED:-false}" = true ] && [ "${NSE_REPLAY_LEAK:-0}" -ne 0 ]; then
  result=FAIL
  reason="$NSE_REPLAY_LEAK object(s) the manifest says are provided to nobody were reachable from the test's substituters anyway (nix copy copies closures); anything the build needed from that set could have been obtained rather than built"
elif [ "$NSE_SOURCES_IN_ESCROW" -ne "$NSE_SOURCES_REQUIRED" ]; then
  result=FAIL
  reason="the durable escrow held only $NSE_SOURCES_IN_ESCROW of $NSE_SOURCES_REQUIRED plan-required sources when asked before isolation, so a green build would not be attributable to it"
elif [ -n "$reason" ]; then
  result=FAIL
elif [ "$build_rc" -eq 0 ] && [ "$eval_rc" -eq 0 ] \
     && [ "$restored" -eq "$required" ] && [ "$out_matches" = true ] \
     && [ "$net_lines" -eq 0 ]; then
  result=PASS
else
  result=FAIL
  if [ "$restored" -ne "$required" ]; then
    reason="only $restored of $required plan-required sources ended up in the test store"
  elif [ "$out_matches" != true ]; then
    reason="built output '$built' does not match the expected output '$expected_out' from the manifest"
  elif [ "$net_lines" -ne 0 ]; then
    reason="build log shows $net_lines fetch(es) over http(s); the escrow was not the only source"
  else
    reason="unspecified failure at step $step"
  fi
fi

jq -n \
  --arg result "$result" --arg reason "$reason" --arg step "$step" \
  --arg built "$built" --arg expected "$expected_out" \
  --arg isolationMode "$NSE_ISOLATION_MODE" \
  --arg isolationSetup "$isolation_setup" \
  --arg setupFailures "$setup_failures" \
  --arg modeSupported "$NSE_MODE_SUPPORTED" \
  --argjson sourcesInEscrow "$NSE_SOURCES_IN_ESCROW" \
  --arg durableEscrow "$NSE_DURABLE_ESCROW" \
  --arg guaranteeName "$NSE_GUARANTEE_NAME" \
  --argjson buildRc "$build_rc" --argjson evalRc "$eval_rc" \
  --argjson required "$required" --argjson restored "$restored" \
  --argjson inputsRequired "$inputs_required" --argjson inputsPresent "$inputs_present" \
  --arg inputsPresentNames "$inputs_present_names" \
  --argjson httpFetches "$net_lines" \
  --argjson outMatches "$out_matches" \
  --argjson reachableOrigins "$reachable_origins" \
  --argjson unresolvedOrigins "$unresolved_origins" \
  --argjson substitutersOk "$substituters_ok" \
  --arg substituters "$effective_substituters" \
  --arg expectedSubstituters "$NSE_SUBSTITUTERS" \
  --arg escrowSubstituter "$NSE_ESCROW_SUBSTITUTER" \
  --arg nss "$nss_isolation" \
  --slurpfile conn "$NSE_WORK/prove-connectivity.json" \
  '{result:$result, reason:(if $reason=="" then null else $reason end), failedStep:$step,
    isolationMode:$isolationMode,
    isolationSetup:$isolationSetup,
    isolationSetupFailures:(if $setupFailures=="" then [] else ($setupFailures|split(",")) end),
    guaranteeName:$guaranteeName,
    modeSupported:($modeSupported == "true"),
    durableEscrow:$durableEscrow,
    sourcesInEscrowBeforeIsolation:$sourcesInEscrow,
    builtOutput:$built, expectedOutput:$expected, outputMatches:$outMatches,
    buildExit:$buildRc, offlineEvalExit:$evalRc,
    offlineEvalProbe:(if $evalRc == 0 then "clean" else "failed" end),
    sourcesRequired:$required, sourcesRestored:$restored,
    flakeInputsRequired:$inputsRequired, flakeInputsPresentAfterBuild:$inputsPresent,
    flakeInputsPresentAfterBuildNames:
      (if $inputsPresentNames == "" then [] else ($inputsPresentNames|split(",")) end),
    httpFetchesInBuildLog:$httpFetches,
    reachableOriginCount:$reachableOrigins,
    unresolvedOriginCount:$unresolvedOrigins,
    substitutersAsExpected:$substitutersOk,
    effectiveSubstituters:$substituters,
    expectedSubstituters:$expectedSubstituters,
    escrowSubstituter:$escrowSubstituter,
    substitutersOnlyEscrow:($substitutersOk and ($expectedSubstituters == $escrowSubstituter)),
    originHostsProvenUnreachable:
      ([$conn[0][]|select(.role=="origin" and .reachableByName==false and .reachableByAddress==false)|.host]),
    originHostsReachable:
      ([$conn[0][]|select(.role=="origin" and (.reachableByName or .reachableByAddress))|.host]),
    nssIsolation:$nss,
    connectivity:$conn[0]}' > "$NSE_WORK/prove-result.json"

[ "$result" = PASS ]
INNER
  chmod +x "$1"
}
