# shellcheck shell=bash
# PROVE: the ORIGIN_INDEPENDENCE acceptance test.
#
# Guarantee under test (A): the accepted build succeeds while every dependency
# origin is unreachable, using only the escrow. This is NOT the same guarantee
# as FULL_AIRGAP_REBUILD -- see DESIGN.md.

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

nse_prove() {
  local expect=${1:-pass}
  local manifest=$NSE_DIR/manifest.json
  local work=$NSE_DIR/work
  local teststore=$work/test-store
  local testhome=$work/test-home
  [ -f "$manifest" ] || nse_die "no manifest.json; run 'nix-source-escrow preserve' first"
  mkdir -p "$work" "$NSE_DIR/evidence"

  nse_step "ORIGIN_INDEPENDENCE acceptance test (expect=$expect)"
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

  local envf=$work/prove-env.sh
  {
    printf 'NSE_CACHE=%q\n'        "$NSE_CACHE"
    printf 'NSE_TESTSTORE=%q\n'    "$teststore"
    printf 'NSE_TESTHOME=%q\n'     "$testhome"
    printf 'NSE_INSTALLABLE=%q\n'  "$NSE_INSTALLABLE"
    printf 'NSE_MANIFEST=%q\n'     "$manifest"
    printf 'NSE_WORK=%q\n'         "$work"
    printf 'NSE_PROBE_IPS=%q\n'    "$(nse_resolve_probe_hosts)"
    printf 'NSE_PWD=%q\n'          "$PWD"
    printf "NSE_TRUSTED_KEYS=%q\n" "${NSE_TRUSTED_KEYS:-cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=}"
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
    --argjson runnerExit "$rc" \
    --slurpfile r "$work/prove-result.json" \
    '$r[0] + {schemaVersion:1, kind:"origin-independence", timestamp:$ts,
              isolation:$isolation, expectation:$expect, runnerExit:$runnerExit}' \
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

  # Report only what was demonstrated. "BLOCKED" lists hosts proven unreachable
  # by both probes -- never the hosts we merely intended to block.
  jq -r '
    "NETWORK_ISOLATION=" + .isolation,
    "ISOLATION_MODE=" + .isolationMode,
    "NSS_ISOLATION=" + .nssIsolation,
    "ORIGIN_HOSTS_PROVEN_UNREACHABLE=" + ((.originHostsProvenUnreachable|join(",")) | if .=="" then "none" else . end),
    "ORIGIN_HOSTS_REACHABLE=" + ((.originHostsReachable|join(",")) | if .=="" then "none" else . end),
    "CACHE_NIXOS_ORG_ALLOWED=" + ([.connectivity[]|select(.host=="cache.nixos.org")|(.reachableByName or .reachableByAddress)]|first|tostring),
    "SUBSTITUTERS_ONLY_ESCROW=" + (.substitutersOnlyEscrow|tostring),
    "OFFLINE_EVAL_PROBE=" + .offlineEvalProbe,
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
      # A negative control must fail *for the right reason*. NOT_ISOLATED is a
      # broken harness, not a demonstration that the escrow was incomplete.
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
# escrow (a plain directory) or a store it created itself.
set -uo pipefail
# shellcheck disable=SC1090
. "$1"

# ---- 1. mount isolation --------------------------------------------------
# glibc NSS reaches nscd/nsncd over a *unix socket*, which a network namespace
# does not isolate; without this, name resolution inside the namespace is still
# answered by the host. It cannot move bytes, but we would rather not have to
# argue about that in the evidence.
nss_isolation=full
if [ "$NSE_ISOLATION_MODE" = none ]; then
  nss_isolation=none
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
  # Loopback, plus a dummy device whose default route points at an address that
  # does not exist. The dummy device exists for exactly one reason: Nix 2.34
  # disables *all* substituters -- including purely local file:// ones -- when
  # it decides the machine has no Internet access. See DESIGN.md.
  ip link set lo up
  ip link add dummy0 type dummy
  ip addr add 10.99.0.1/24 dev dummy0
  ip link set dummy0 up
  ip route add default via 10.99.0.254 dev dummy0
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
export NIX_CONFIG="experimental-features = nix-command flakes
substituters = file://$NSE_CACHE
trusted-substituters =
trusted-public-keys = $NSE_TRUSTED_KEYS
require-sigs = true
flake-registry =
warn-dirty = false
build-users-group =
require-drop-supplementary-groups = false
"

cd "$NSE_PWD" || { printf 'prove: cannot cd to %s\n' "$NSE_PWD" >&2; exit 90; }

# The escrow must be the ONLY substituter. If anything else were configured, a
# green build would not tell us where the sources came from.
effective_substituters=$(nix config show substituters 2>/dev/null | tr -s ' ')
expected_substituters="file://$NSE_CACHE"
if [ "$effective_substituters" = "$expected_substituters" ]; then
  substituters_ok=true
else
  substituters_ok=false
fi

reason=""
step=""

# ---- 4. restore flake input material from the escrow ---------------------
# A locked flake input is re-fetched from its origin unless the store already
# holds it: Nix derives the expected store path from the narHash in the lock
# and uses it when it is valid. This is the escrow RECOVER step, done offline.
step=restore-flake-inputs
mapfile -t inputs < <(jq -r '.flakeInputs[] | select(.escrow.present) | .storePath' "$NSE_MANIFEST")
restore_rc=0
if [ "${#inputs[@]}" -gt 0 ]; then
  nix copy --from "file://$NSE_CACHE" --to "$NSE_TESTSTORE" "${inputs[@]}" \
    > "$NSE_WORK/prove-restore.log" 2>&1
  restore_rc=$?
fi
[ "$restore_rc" -eq 0 ] || reason="flake input restore from the escrow failed (see prove-restore.log)"

# ---- 5. offline evaluation probe -----------------------------------------
# This is the ONLY thing that can cover eval-time fetches. builtins.fetchTarball
# / fetchGit / fetchurl with a pinned hash never appear in the derivation graph,
# so discovery cannot enumerate them. Here the evaluation runs with no network
# and an empty XDG_CACHE_HOME, so any such fetch has nowhere to come from and
# this probe fails instead of the gap passing silently.
eval_rc=1
if [ -z "$reason" ]; then
  step=offline-eval-probe
  nix path-info --derivation --store "$NSE_TESTSTORE" "$NSE_INSTALLABLE" \
    > "$NSE_WORK/prove-eval.log" 2>&1
  eval_rc=$?
  [ "$eval_rc" -eq 0 ] || reason="evaluation failed offline; an eval-time fetch is not covered by the escrow (see prove-eval.log)"
fi

# ---- 6. the build --------------------------------------------------------
built=""
build_rc=1
if [ -z "$reason" ]; then
  step=build
  built=$(nix build --store "$NSE_TESTSTORE" "$NSE_INSTALLABLE" --no-link --print-out-paths \
          2> "$NSE_WORK/prove-build.log")
  build_rc=$?
  [ "$build_rc" -eq 0 ] || reason="build failed under origin blackout (see prove-build.log)"
fi

# ---- 7. did the sources really come from the escrow? ---------------------
# The store started empty and nothing was reachable, so a valid source path in
# the test store can only have come from the escrow.
step=post-checks
required=0; restored=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  required=$((required + 1))
  if nix path-info --store "$NSE_TESTSTORE" "$p" >/dev/null 2>&1; then
    restored=$((restored + 1))
  fi
done < <(jq -r '.sources[] | select(.plan.requiredByPlan) | .storePath' "$NSE_MANIFEST")

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
# ordering exists to prevent.
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
elif [ "$substituters_ok" != true ]; then
  result=FAIL
  reason="substituters were '$effective_substituters', expected only '$expected_substituters'"
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
  --argjson buildRc "$build_rc" --argjson restoreRc "$restore_rc" --argjson evalRc "$eval_rc" \
  --argjson required "$required" --argjson restored "$restored" \
  --argjson httpFetches "$net_lines" \
  --argjson outMatches "$out_matches" \
  --argjson reachableOrigins "$reachable_origins" \
  --argjson unresolvedOrigins "$unresolved_origins" \
  --argjson substitutersOk "$substituters_ok" \
  --arg substituters "$effective_substituters" \
  --arg nss "$nss_isolation" \
  --slurpfile conn "$NSE_WORK/prove-connectivity.json" \
  '{result:$result, reason:(if $reason=="" then null else $reason end), failedStep:$step,
    isolationMode:$isolationMode,
    builtOutput:$built, expectedOutput:$expected, outputMatches:$outMatches,
    buildExit:$buildRc, restoreExit:$restoreRc, offlineEvalExit:$evalRc,
    offlineEvalProbe:(if $evalRc == 0 then "clean" else "failed" end),
    sourcesRequired:$required, sourcesRestored:$restored,
    httpFetchesInBuildLog:$httpFetches,
    reachableOriginCount:$reachableOrigins,
    unresolvedOriginCount:$unresolvedOrigins,
    substitutersOnlyEscrow:$substitutersOk, effectiveSubstituters:$substituters,
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
