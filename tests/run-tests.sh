#!/usr/bin/env bash
#
# Automated tests for nix-source-escrow.
#
#   nix develop -c ./tests/run-tests.sh          # full suite
#   NSE_TEST_REUSE=1 nix develop -c ./tests/run-tests.sh   # skip re-preserving
#
# The suite is deliberately built around one real escrow of the fixture: every
# negative case is a *derived, deliberately damaged copy* of that escrow, so the
# thing under test is always the real artefact and not a mock.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NSE=$ROOT/bin/nix-source-escrow
ESCROW=${NSE_TEST_ESCROW:-$ROOT/escrow}
FIXTURE="path:$ROOT/fixture#default"
WORK=$ESCROW/work/tests

pass=0; fail=0; failed_names=()

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n    %s\n' "$1" "${2:-}"; fail=$((fail+1)); failed_names+=("$1"); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "expected something other than '$2'"; fi
}

command -v jq  >/dev/null || { echo "tests: jq not on PATH; run inside 'nix develop'" >&2; exit 2; }
command -v nix >/dev/null || { echo "tests: nix not on PATH" >&2; exit 2; }

# Store paths are 0555; a plain rm -rf on a store tree fails.
rm_store() { [ -e "$1" ] || return 0; chmod -R u+w "$1" 2>/dev/null || :; rm -rf "$1"; }

# Would `--expect-fail` accept this result as a valid negative control?
# Echoes the exit status nse_prove_report would return. Only a genuine FAIL
# counts: NOT_ISOLATED and HARNESS_ERROR are broken harnesses.
nse_expect_fail_rc() {
  case "$(jq -r '.result' "$1")" in
    FAIL) printf '0\n' ;;
    *)    printf '1\n' ;;
  esac
}

# A full copy of the escrow, so a deliberately damaged variant can never write
# back into the real one. Hardlinking here would be faster and was tried; a
# `sed ... > file` writes *through* a hardlink and silently corrupts the
# original, which is exactly the bug this comment exists to prevent.
mk_escrow_copy() {
  local dest=$1
  rm_store "$dest"; mkdir -p "$dest"
  command cp -a "$ESCROW/cache" "$dest/cache"
  local f
  for f in manifest.json closure.json discovery.json; do
    command cp -f "$ESCROW/$f" "$dest/$f"
  done
  mkdir -p "$dest/evidence"
}

# Drop an object (narinfo + its nar) from a cache directory.
drop_object() {
  local cache=$1 storepath=$2
  local hp=${storepath##*/}; hp=${hp%%-*}
  local ni=$cache/$hp.narinfo
  [ -f "$ni" ] || { echo "drop_object: no narinfo for $storepath" >&2; return 1; }
  local nar; nar=$(sed -n 's/^URL: //p' "$ni")
  rm -f "$ni"
  [ -n "$nar" ] && rm -f "$cache/$nar"
  return 0
}

mkdir -p "$ESCROW"

# ---------------------------------------------------------------------------
head_ "t00  shell-level units (no Nix, no network, no namespaces)"
if "$ROOT/tests/unit-shell.sh" > "$ESCROW/unit-shell.log" 2>&1; then
  ok "t00.1 tests/unit-shell.sh passes ($(grep -c 'PASS' "$ESCROW/unit-shell.log") checks)"
else
  bad "t00.1 tests/unit-shell.sh" "see $ESCROW/unit-shell.log"
fi

# ---------------------------------------------------------------------------
head_ "setup: build the reference escrow"
if [ "${NSE_TEST_REUSE:-0}" = 1 ] && [ -f "$ESCROW/manifest.json" ]; then
  echo "  reusing existing escrow at $ESCROW (NSE_TEST_REUSE=1)"
else
  "$NSE" discover "$FIXTURE" >/dev/null
  "$NSE" preserve "$FIXTURE" >/dev/null
fi
"$NSE" env >/dev/null
mkdir -p "$WORK"

MANIFEST=$ESCROW/manifest.json
DISCOVERY=$ESCROW/discovery.json
mapfile -t REQUIRED_SOURCES < <(jq -r '.sources[]|select(.plan.requiredByPlan)|.storePath' "$MANIFEST")

# ---------------------------------------------------------------------------
head_ "t01  source discovery"
assert_eq "t01.1 discovery.json is valid JSON" \
  "ok" "$(jq -e . "$DISCOVERY" >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "t01.2 all four distinct flake input objects discovered" \
  "4" "$(jq -r ".counts.flakeInputs" "$DISCOVERY")"
assert_eq "t01.2a the walk descended into the nested input tree" \
  "6" "$(jq -r ".counts.flakeInputEdgesWalked" "$DISCOVERY")"
assert_eq "t01.2b the transitive input flake-utils/systems was found" \
  "true" "$(jq -r "[.flakeInputs[].aliasPaths[]]|index(\"flake-utils/systems\") != null" "$DISCOVERY")"
assert_eq "t01.2c a renamed lock node is resolved by graph, not by alias name" \
  "systems_2" "$(jq -r ".flakeInputs[]|select(.name==\"systems\")|.lockNodeId" "$DISCOVERY")"
assert_eq "t01.2d a follows edge resolves to the same object, deduplicated" \
  "2" "$(jq -r "[.flakeInputs[]|select(.name==\"flake-utils\")|.aliasPaths[]]|length" "$DISCOVERY")"
assert_eq "t01.2e every input resolved to a lock node" \
  "0" "$(jq -r ".counts.flakeInputsUnknown" "$DISCOVERY")"
assert_eq "t01.3 fetchFromGitHub source found, nar hash, postFetch flagged" \
  "nar true true" \
  "$(jq -r '[.sources[]|select(.origin.urls[]?|test("nix-pills"))]|.[0]|"\(.hashMode) \(.transform.postFetch) \(.transform.stripRoot)"' "$DISCOVERY")"
assert_eq "t01.4 flat fetchurl source found with flat hash and no postFetch" \
  "flat false" \
  "$(jq -r '[.sources[]|select(.kind=="fetchurl" and (.origin.urls[]?|test("hello-2.12.1")))]|.[0]|"\(.hashMode) \(.transform.postFetch)"' "$DISCOVERY")"
assert_eq "t01.5 no source left UNKNOWN" "0" "$(jq -r '.counts.sourcesUnknown' "$DISCOVERY")"
assert_eq "t01.6 no source left UNSUPPORTED" "0" "$(jq -r '.counts.sourcesUnsupported' "$DISCOVERY")"
assert_eq "t01.7 origin-less bootstrap FODs classified EXTERNAL_RECOVERY, not UNKNOWN" \
  "2" "$(jq -r '.counts.sourcesExternalRecovery' "$DISCOVERY")"
assert_eq "t01.8 IFD probe ran and reports a definite answer" \
  "absent" "$(jq -r '.evalTimeFetches.ifd.status' "$DISCOVERY")"

# ---------------------------------------------------------------------------
head_ "t02  manifest generation"
assert_eq "t02.1 manifest.json is valid JSON" \
  "ok" "$(jq -e . "$MANIFEST" >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "t02.2 every source record carries the required fields" \
  "0" "$(jq -r '[.sources[]|select((has("kind") and has("expectedHash") and has("hashMode")
                                    and has("origin") and has("discovery") and has("escrow")
                                    and has("plan"))|not)]|length' "$MANIFEST")"
assert_eq "t02.3 every source has a discovery status from the model" \
  "0" "$(jq -r '[.sources[]|select(.discovery.status
                 |IN("COVERED","EXTERNAL_RECOVERY","QUARANTINED","UNKNOWN","UNSUPPORTED")|not)]|length' "$MANIFEST")"
assert_eq "t02.4 manifest records the expected build output" \
  "1" "$(jq -r '.expectedOutputs|length' "$MANIFEST")"
assert_eq "t02.5 manifest carries no timestamp (canonical, not probe data)" \
  "false" "$(jq -r '[paths|map(tostring)|join(".")]|any(test("timestamp";"i"))' "$MANIFEST")"
assert_eq "t02.6 manifest names the guarantee it was built for" \
  "escrow-replay" "$(jq -r '.guarantee' "$MANIFEST")"
assert_eq "t02.7 the escrow is addressed by URL, and the backend is derived from it" \
  "local-file-binary-cache true" \
  "$(jq -r '"\(.escrow.backend) \((.escrow.storeUrl|startswith("file://")) and (.escrow.substituterUrl|startswith("file://")))"' "$MANIFEST")"
assert_eq "t02.8 under ESCROW_REPLAY there is no binary replica" \
  "null" "$(jq -r '.escrow.binaryReplicaUrl' "$MANIFEST")"
assert_eq "t02.9 closure.json splits escrow from replica" \
  "true" "$(jq -r '(.escrowPaths|length) == (.paths|length) and ((.replicaPaths|length) == 0)' "$ESCROW/closure.json")"

# ---------------------------------------------------------------------------
head_ "t03  preservation"
assert_eq "t03.1 every discovered flake input is in the escrow" \
  "true" "$(jq -r "([.flakeInputs[]|select(.escrow.present)]|length) == .counts.flakeInputs" "$MANIFEST")"
assert_eq "t03.2 all plan-required sources preserved" \
  "0" "$(jq -r '.counts.sourcesMissing' "$MANIFEST")"
assert_ne "t03.3 the plan actually required some sources" "0" "${#REQUIRED_SOURCES[@]}"
n_missing_narinfo=0
for p in "${REQUIRED_SOURCES[@]}"; do
  hp=${p##*/}; hp=${hp%%-*}
  [ -f "$ESCROW/cache/$hp.narinfo" ] || n_missing_narinfo=$((n_missing_narinfo+1))
done
assert_eq "t03.4 every required source has a narinfo on disk" "0" "$n_missing_narinfo"
assert_eq "t03.5 verify passes on the intact escrow" \
  "0" "$("$NSE" verify "$FIXTURE" >/dev/null 2>&1 && echo 0 || echo $?)"
VJ=$ESCROW/evidence/verify.json
assert_eq "t03.6 NAR integrity covers the WHOLE closure, not just the sources" \
  "full-closure" "$(jq -r ".narIntegrity.scope" "$VJ")"
assert_eq "t03.7 the number of NAR-verified paths equals the closure size" \
  "true" "$(jq -r ".narIntegrity.pathsChecked == .presence.closurePaths" "$VJ")"

# ---------------------------------------------------------------------------
head_ "t04  idempotency"
before=$(sha256sum "$MANIFEST" | cut -d' ' -f1)
"$NSE" discover "$FIXTURE" >/dev/null
after_discover=$(sha256sum "$DISCOVERY" | cut -d' ' -f1)
"$NSE" discover "$FIXTURE" >/dev/null
assert_eq "t04.1 discover is deterministic across runs" \
  "$after_discover" "$(sha256sum "$DISCOVERY" | cut -d' ' -f1)"
"$NSE" preserve "$FIXTURE" >/dev/null
assert_eq "t04.2 manifest is byte-identical after a second preserve" \
  "$before" "$(sha256sum "$MANIFEST" | cut -d' ' -f1)"

# ---------------------------------------------------------------------------
head_ "t05  missing source object"
mk_escrow_copy "$WORK/missing"
drop_object "$WORK/missing/cache" "${REQUIRED_SOURCES[0]}"
rc=0; "$NSE" verify "$FIXTURE" --escrow-dir "$WORK/missing" >"$WORK/missing.log" 2>&1 || rc=$?
assert_ne "t05.1 verify fails when a required source is absent" "0" "$rc"
assert_eq "t05.2 verify names it as a presence failure" \
  "1" "$(jq -r '.presence.missing' "$WORK/missing/evidence/verify.json")"

# ---------------------------------------------------------------------------
head_ "t06  corrupted cache object / hash mismatch"
mk_escrow_copy "$WORK/corrupt"
hp=${REQUIRED_SOURCES[0]##*/}; hp=${hp%%-*}
nar=$(sed -n 's/^URL: //p' "$WORK/corrupt/cache/$hp.narinfo")
printf 'CORRUPTED' | dd of="$WORK/corrupt/cache/$nar" bs=1 seek=64 conv=notrunc status=none
rc=0; "$NSE" verify "$FIXTURE" --escrow-dir "$WORK/corrupt" >"$WORK/corrupt.log" 2>&1 || rc=$?
assert_ne "t06.1 verify fails on a corrupted NAR" "0" "$rc"
assert_eq "t06.2 verify attributes it to NAR integrity" \
  "FAILED" "$(jq -r '.narIntegrity.status' "$WORK/corrupt/evidence/verify.json")"

mk_escrow_copy "$WORK/wronghash"
hp=${REQUIRED_SOURCES[0]##*/}; hp=${hp%%-*}
sed 's|^CA: fixed:r:sha256:.*|CA: fixed:r:sha256:0000000000000000000000000000000000000000000000000000|' \
  -i "$WORK/wronghash/cache/$hp.narinfo"
rc=0; "$NSE" verify "$FIXTURE" --escrow-dir "$WORK/wronghash" >"$WORK/wronghash.log" 2>&1 || rc=$?
assert_ne "t06.3 verify fails when the content address does not match the derivation" "0" "$rc"
assert_ne "t06.4 verify attributes it to content identity" \
  "0" "$(jq -r '.contentIdentity.mismatched' "$WORK/wronghash/evidence/verify.json")"

# ---------------------------------------------------------------------------
head_ "t07  origin blocked + escrow available  (the acceptance criterion)"
rc=0; "$NSE" test-origin-independence "$FIXTURE" >"$WORK/oi.log" 2>&1 || rc=$?
OI=$ESCROW/evidence/origin-independence.json
assert_eq "t07.1 ORIGIN_INDEPENDENCE=PASS" "0" "$rc"
assert_eq "t07.2 result recorded as PASS" "PASS" "$(jq -r '.result' "$OI")"
assert_eq "t07.3 no origin host was reachable by name or by address" \
  "0" "$(jq -r '[.connectivity[]|select(.role=="origin" and (.reachableByName or .reachableByAddress))]|length' "$OI")"
assert_eq "t07.4 origin hosts were probed by pre-resolved address, not just by name" \
  "0" "$(jq -r '[.connectivity[]|select(.role=="origin" and .preResolvedAddress=="unresolved")]|length' "$OI")"
assert_eq "t07.5 the build fetched nothing over http(s)" \
  "0" "$(jq -r '.httpFetchesInBuildLog' "$OI")"
assert_eq "t07.6 output path matches the manifest" "true" "$(jq -r '.outputMatches' "$OI")"
assert_eq "t07.7 every plan-required source ended up in the clean test store" \
  "true" "$(jq -r '.sourcesRestored == .sourcesRequired' "$OI")"
assert_eq "t07.8 NSS was isolated too, so DNS was not merely broken" \
  "full" "$(jq -r ".nssIsolation" "$OI")"
assert_eq "t07.9 flake inputs were restored from the escrow with no network" \
  "0" "$(jq -r ".restoreExit" "$OI")"
assert_eq "t07.10 evaluation itself succeeded offline (covers eval-time builtins.fetch*)" \
  "clean" "$(jq -r ".offlineEvalProbe" "$OI")"
assert_eq "t07.11 the escrow was the only substituter" \
  "true" "$(jq -r ".substitutersOnlyEscrow" "$OI")"
assert_eq "t07.12 zero origin hosts were reachable" \
  "0" "$(jq -r ".reachableOriginCount" "$OI")"
assert_eq "t07.13 the report names only hosts proven unreachable" \
  "true" "$(jq -r "(.originHostsProvenUnreachable|length) > 0 and (.originHostsReachable|length) == 0" "$OI")"

# ---------------------------------------------------------------------------
head_ "t08  origin blocked + escrow missing  (must FAIL)"
mk_escrow_copy "$WORK/nosource"
for p in "${REQUIRED_SOURCES[@]}"; do drop_object "$WORK/nosource/cache" "$p"; done
rc=0
"$NSE" test-origin-independence "$FIXTURE" --escrow-dir "$WORK/nosource" --expect-fail \
  >"$WORK/nosource.log" 2>&1 || rc=$?
assert_eq "t08.1 negative control: the tool reports the expected failure" "0" "$rc"
assert_eq "t08.2 the build genuinely failed" \
  "FAIL" "$(jq -r '.result' "$WORK/nosource/evidence/origin-independence.json")"
assert_ne "t08.3 a reason was recorded" \
  "null" "$(jq -r '.reason' "$WORK/nosource/evidence/origin-independence.json")"

# ---------------------------------------------------------------------------
head_ "t09  trust: what does this Nix accept unsigned?"
"$NSE" trust-probe --escrow-dir "$ESCROW" >"$WORK/trust.log" 2>&1
TJ=$ESCROW/evidence/trust.json
assert_eq "t09.1 unsigned content-addressed source accepted with NO trusted keys" \
  "ok" "$(jq -r '.results.contentAddressedSource_noTrustedKeys' "$TJ")"
assert_eq "t09.2 signed input-addressed path accepted with the cache.nixos.org key" \
  "ok" "$(jq -r '.results.signedInputAddressed_cacheNixosOrgKey' "$TJ")"
assert_eq "t09.3 the same signed path is refused with no trusted keys" \
  "denied" "$(jq -r '.results.signedInputAddressed_noTrustedKeys' "$TJ")"
assert_eq "t09.4 unsigned input-addressed path is refused" \
  "denied" "$(jq -r '.results.unsignedInputAddressed_cacheNixosOrgKey' "$TJ")"
assert_eq "t09.5 conclusion: a source-only escrow needs no signing" \
  "false" "$(jq -r '.conclusion.sourceSignatureRequired' "$TJ")"

# ---------------------------------------------------------------------------
head_ "t10  postFetch: upstream bytes are not the fixed-output result"
# Three sources fetch THE SAME BYTES FROM THE SAME URL and become three
# different Nix objects. Nothing else varies between them, so this isolates the
# transformation as the only cause.
HELLO_URL="https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz"
same_url_count=$(jq -r --arg u "$HELLO_URL" \
  '[.sources[]|select((.origin.urls[0] // "") == $u)]|length' "$DISCOVERY")
assert_eq "t10.1 exactly three sources share one identical upstream URL" "3" "$same_url_count"
distinct_hashes=$(jq -r --arg u "$HELLO_URL" \
  '[.sources[]|select((.origin.urls[0] // "") == $u)|.expectedHash]|unique|length' "$DISCOVERY")
assert_eq "t10.2 that one URL yields three distinct Nix identities" "3" "$distinct_hashes"

# The two fetchzip sources differ in exactly one attribute: stripRoot.
zip_true=$(jq -r --arg u "$HELLO_URL" \
  '[.sources[]|select((.origin.urls[0] // "")==$u and .kind=="fetchzip-like" and .transform.stripRoot==true)]|.[0].expectedHash' "$DISCOVERY")
zip_false=$(jq -r --arg u "$HELLO_URL" \
  '[.sources[]|select((.origin.urls[0] // "")==$u and .kind=="fetchzip-like" and .transform.stripRoot==false)]|.[0].expectedHash' "$DISCOVERY")
flat_hash=$(jq -r --arg u "$HELLO_URL" \
  '[.sources[]|select((.origin.urls[0] // "")==$u and .kind=="fetchurl")]|.[0].expectedHash' "$DISCOVERY")
assert_ne "t10.3 stripRoot alone changes the fixed-output hash" "$zip_true" "$zip_false"
assert_ne "t10.4 flat hash differs from the recursive hash of the same bytes" "$flat_hash" "$zip_true"
assert_eq "t10.5 both fetchzip variants are recursive-hash with postFetch" \
  "nar true nar true" \
  "$(jq -r --arg u "$HELLO_URL" '[.sources[]|select((.origin.urls[0] // "")==$u and .kind=="fetchzip-like")]|sort_by(.transform.stripRoot|tostring)|map("\(.hashMode) \(.transform.postFetch)")|join(" ")' "$DISCOVERY")"

# fetchFromGitHub is the same *class* of transformation but a different URL, so
# it is asserted separately rather than folded into the claim above.
assert_eq "t10.6 fetchFromGitHub is recursive-hash with postFetch and stripRoot (different URL)" \
  "nar true true" \
  "$(jq -r '[.sources[]|select((.origin.urls[0] // "")|test("nix-pills"))]|.[0]|"\(.hashMode) \(.transform.postFetch) \(.transform.stripRoot)"' "$DISCOVERY")"

# ---------------------------------------------------------------------------
head_ "t12  the acceptance test refuses to pass without real isolation"
# The bug this guards against: a control run reporting ORIGIN_INDEPENDENCE=PASS
# with exit 0 while github.com was reachable.
rc=0
"$NSE" test-origin-independence "$FIXTURE" --no-isolation >"$WORK/noiso.log" 2>&1 || rc=$?
NOISO=$ESCROW/evidence/origin-independence.json
assert_ne "t12.1 a run without isolation exits non-zero" "0" "$rc"
assert_eq "t12.2 and its verdict is NOT_ISOLATED, never PASS" \
  "NOT_ISOLATED" "$(jq -r '.result' "$NOISO")"
assert_eq "t12.3 it does not claim reachable hosts were blocked" \
  "true" "$(jq -r '(.originHostsProvenUnreachable|length) == 0' "$NOISO")"

# Harder case: isolation is *claimed* but not actually applied. The verdict must
# still refuse, on the strength of the connectivity probes alone.
FORGE=$WORK/forged
rm_store "$FORGE"; mkdir -p "$FORGE/store" "$FORGE/home"
sed -e "s|^NSE_ISOLATION_MODE=.*|NSE_ISOLATION_MODE=namespaces|" \
    -e "s|^NSE_WORK=.*|NSE_WORK=$FORGE|" \
    -e "s|^NSE_TESTSTORE=.*|NSE_TESTSTORE=$FORGE/store|" \
    -e "s|^NSE_TESTHOME=.*|NSE_TESTHOME=$FORGE/home|" \
    "$ESCROW/work/prove-env.sh" > "$FORGE/env.sh"
bash "$ESCROW/work/prove-inner.sh" "$FORGE/env.sh" >"$WORK/forged.log" 2>&1 || :
if [ -f "$FORGE/prove-result.json" ]; then
  assert_eq "t12.4 claimed-but-absent isolation is caught by the connectivity probes" \
    "FAIL" "$(jq -r '.result' "$FORGE/prove-result.json")"
  assert_eq "t12.5 and the reason names the reachable origins" \
    "true" "$(jq -r '(.reason // "") | test("reachable")' "$FORGE/prove-result.json")"
  assert_ne "t12.6 the probes actually saw the origins as reachable" \
    "0" "$(jq -r '.reachableOriginCount' "$FORGE/prove-result.json")"
else
  bad "t12.4 claimed-but-absent isolation is caught" "runner produced no result file"
fi

# Leave the escrow evidence reflecting a real, isolated run.
"$NSE" test-origin-independence "$FIXTURE" >"$WORK/oi-restore.log" 2>&1
assert_eq "t12.7 a real isolated run still passes afterwards" \
  "PASS" "$(jq -r '.result' "$OI")"

head_ "t11  flake inputs come from a real forge and survive it being blocked"
# Phase 1 of the design: flake input material must be obtainable after archiving
# without touching its origin. Both inputs are locked to github.com, github.com
# was unreachable during t07 by name and by address, and the build still
# evaluated -- which it cannot do without them.
assert_eq "t11.1 nixpkgs is locked to a github origin" \
  "github" "$(jq -r '.flakeInputs[]|select(.name=="nixpkgs")|.type' "$MANIFEST")"
assert_eq "t11.2 the flake=false input is locked to a github origin too" \
  "github" "$(jq -r '.flakeInputs[]|select(.name=="gitignore-src")|.type' "$MANIFEST")"
assert_eq "t11.3 every flake input carries a narHash identity" \
  "0" "$(jq -r '[.flakeInputs[]|select(.narHash==null)]|length' "$MANIFEST")"
assert_eq "t11.4 github.com was unreachable by name AND by address during t07" \
  "1" "$(jq -r '[.connectivity[]|select(.host=="github.com" and .reachableByName==false and .reachableByAddress==false)]|length' "$OI")"
assert_eq "t11.5 every input store path, transitive ones included, is in the escrow" \
  "true" "$(jq -r "([.flakeInputs[]|select(.escrow.present)]|length) == .counts.flakeInputs and .counts.flakeInputs > 0" "$MANIFEST")"

# ---------------------------------------------------------------------------
head_ "t13  the report states what was measured, including the machine"
# The bug: `HOST=Windows 11` was a literal in lib/report.sh, printed on every
# machine, in a tool whose stated rule is that the report says what was
# demonstrated. It even reached EVIDENCE.md as a measured fact.
"$NSE" report >"$WORK/report.log" 2>&1
REPORT=$ESCROW/evidence/report.txt
ENVJ=$ESCROW/evidence/environment.json
assert_ne "t13.1 the recorded host is not the old hardcoded string" \
  "Windows 11" "$(jq -r '.host.kind' "$ENVJ")"
assert_ne "t13.2 and the evidence says how it was determined" \
  "" "$(jq -r '.host.method' "$ENVJ")"
assert_eq "t13.3 the report's HOST line is that recorded value, verbatim" \
  "HOST=$(jq -r '.host.kind' "$ENVJ")" "$(grep -m1 '^HOST=' "$REPORT")"
assert_eq "t13.4 the report records the detection method too" \
  "1" "$(grep -c '^HOST_DETECTED_BY=' "$REPORT")"
assert_eq "t13.5 the report names the guarantee under test" \
  "ESCROW_REPLAY" "$(sed -n 's/^GUARANTEE=//p' "$REPORT" | tail -1)"
assert_eq "t13.6 and states what that guarantee does NOT prove" \
  "1" "$(grep -c '^  does not prove: ' "$REPORT")"

# ---------------------------------------------------------------------------
head_ "t14  a half-applied harness is its own verdict, never an escrow verdict"
# The bug: `ip link add dummy0` ran unchecked under `set -uo pipefail`. With no
# `dummy` module in the kernel the interface silently never appeared and the
# run came back FAIL with reason "build failed under origin blackout" -- an
# accusation against the escrow for a fault in the harness.
FAKEBIN=$WORK/fakebin; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/ip"; chmod +x "$FAKEBIN/ip"
HARN=$WORK/harness; rm_store "$HARN"; mkdir -p "$HARN/store" "$HARN/home"
sed -e "s|^NSE_WORK=.*|NSE_WORK=$HARN|" \
    -e "s|^NSE_TESTSTORE=.*|NSE_TESTSTORE=$HARN/store|" \
    -e "s|^NSE_TESTHOME=.*|NSE_TESTHOME=$HARN/home|" \
    "$ESCROW/work/prove-env.sh" > "$HARN/env.sh"
env PATH="$FAKEBIN:$PATH" unshare -Ur --net --mount -- \
  bash "$ESCROW/work/prove-inner.sh" "$HARN/env.sh" >"$WORK/harness.log" 2>&1 || :
if [ -f "$HARN/prove-result.json" ]; then
  assert_eq "t14.1 a failed isolation setup yields HARNESS_ERROR, not FAIL" \
    "HARNESS_ERROR" "$(jq -r '.result' "$HARN/prove-result.json")"
  assert_eq "t14.2 it is recorded as a setup failure" \
    "failed" "$(jq -r '.isolationSetup' "$HARN/prove-result.json")"
  assert_ne "t14.3 and names which operations failed" \
    "0" "$(jq -r '.isolationSetupFailures|length' "$HARN/prove-result.json")"
  assert_eq "t14.4 the reason does not blame the escrow" \
    "false" "$(jq -r '(.reason // "") | test("build failed")' "$HARN/prove-result.json")"
  assert_eq "t14.5 HARNESS_ERROR is not accepted as a negative control either" \
    "1" "$(nse_expect_fail_rc "$HARN/prove-result.json")"
else
  bad "t14.1 a failed isolation setup yields HARNESS_ERROR" "runner produced no result file"
fi

# ---------------------------------------------------------------------------
head_ "t15  SOURCE_ORIGIN_INDEPENDENCE is a different, weaker, cheaper claim"
# Two defects this group exists for. v1 of the mode filled the binary replica
# with `closure - sources` copied out of the STAGING store, so an object this
# machine built was served as though the approved cache had it. v2 then read a
# cache signature as proof of substitution and refused the whole mode when the
# tier lacked such a path -- but a signature is not proof of substitution, and
# "staging chose to download X" says nothing about whether X can be built.
# The tier now supplies what it has; everything else is rebuilt by the test,
# and the test is the judge of whether that works.
if [ "${NSE_TEST_SKIP_MODES:-0}" = 1 ]; then
  echo "  skipped (NSE_TEST_SKIP_MODES=1)"
else
  SRC=$WORK/srcmode
  rm_store "$SRC"; mkdir -p "$SRC"
  rc=0
  "$NSE" escrow "$FIXTURE" \
    --escrow-dir "$SRC" \
    --guarantee source-origin-independence \
    --binary-tier "${NSE_TEST_BINARY_TIER:-https://cache.nixos.org}" \
    --staging-dir "$ESCROW/work/staging" >"$WORK/srcmode.log" 2>&1 || rc=$?
  SRC_OI=$SRC/evidence/origin-independence.json
  SRC_MANIFEST=$SRC/manifest.json
  SRC_CLOSURE=$SRC/closure.json

  assert_eq "t15.1 the source-only guarantee passes end to end" "0" "$rc"
  assert_eq "t15.2 the manifest names the weaker guarantee" \
    "source-origin-independence" "$(jq -r '.guarantee' "$SRC_MANIFEST")"
  assert_eq "t15.3 and the approved binary tier it was built against" \
    "true" "$(jq -r '(.binaryTier.url // "") | length > 0' "$SRC_MANIFEST")"
  assert_eq "t15.4 the escrow holds source material only, not the whole closure" \
    "true" "$(jq -r '(.escrowPaths|length) < (.paths|length)' "$SRC_CLOSURE")"
  assert_eq "t15.5 every plan-required source is still in the escrow itself" \
    "0" "$(jq -r '.counts.sourcesMissing' "$SRC_MANIFEST")"
  assert_eq "t15.6 every flake input is still in the escrow itself" \
    "true" "$(jq -r '.counts.flakeInputsPresent == .counts.flakeInputs' "$SRC_MANIFEST")"
  assert_eq "t15.7 the verdict is labelled with the weaker guarantee" \
    "SOURCE_ORIGIN_INDEPENDENCE" "$(jq -r '.guarantee.name' "$SRC_OI")"
  assert_eq "t15.8 and it does NOT claim the escrow was the only substituter" \
    "false" "$(jq -r '.substitutersOnlyEscrow' "$SRC_OI")"
  assert_eq "t15.9 the escrow was still asked for every required source, before isolation" \
    "true" "$(jq -r '.sourcesInEscrowBeforeIsolation == .sourcesRequired and .sourcesRequired > 0' "$SRC_OI")"
  assert_eq "t15.10 the evidence spells out what this does not prove" \
    "true" "$(jq -r '.guarantee.doesNotProve | test("ESCROW_REPLAY")' "$SRC_OI")"
  # The fidelity assertion: the replica is exactly what the tier answered with.
  assert_eq "t15.11 the replica holds exactly what the tier supplied" \
    "true" "$(jq -r --slurpfile m "$SRC_MANIFEST" '(.replicaPaths|length) == $m[0].binaryTier.pathsFromTier' "$SRC_CLOSURE")"
  assert_eq "t15.12 objects nobody supplies are recorded, not silently escrowed" \
    "true" "$(jq -r '(.notProvidedPaths|length) > 0' "$SRC_CLOSURE")"
  assert_eq "t15.13 the .drv files are among them -- a binary cache is not asked for a derivation" \
    "true" "$(jq -r '[.notProvidedPaths[]|select(endswith(".drv"))]|length > 0' "$SRC_CLOSURE")"
  assert_eq "t15.14 nothing is in both the escrow and the replica" \
    "0" "$(jq -r '[.escrowPaths[]] as $e | [.replicaPaths[]|select(. as $p | $e|index($p))]|length' "$SRC_CLOSURE")"
  assert_eq "t15.15 the three sets account for the whole realised closure" \
    "true" "$(jq -r '((.escrowPaths + .replicaPaths + .notProvidedPaths)|unique|length) == (.paths|length)' "$SRC_CLOSURE")"
  assert_eq "t15.16 no .drv was ever asked of the tier" \
    "true" "$(jq -r --slurpfile c "$SRC_CLOSURE" '.binaryTier.pathsRequested == (($c[0].replicaPaths + [$c[0].notProvidedPaths[]|select(endswith(".drv")|not)])|unique|length)' "$SRC_MANIFEST")"
  # The accounting the third review asked for: `nix copy` copies closures, so
  # what the test can REACH is measured, not inferred from what was requested.
  assert_eq "t15.17 what the test could reach was measured, not assumed" \
    "number" "$(jq -r '.replaySource.objectsReachableByTest | type' "$SRC_OI")"
  assert_eq "t15.18 nothing marked provided-to-nobody was reachable after all" \
    "0" "$(jq -r '.replaySource.notProvidedReachableByTest' "$SRC_OI")"
  assert_eq "t15.19 the strict escrow is untouched and still ESCROW_REPLAY" \
    "escrow-replay" "$(jq -r '.guarantee' "$MANIFEST")"
fi

# ---------------------------------------------------------------------------
head_ "t16  a remote escrow is replayed from a proof replica, not pretended to be reachable"
# PRESERVE and VERIFY can address any Nix store URL. The acceptance test cannot:
# it cuts all egress, so an HTTPS/S3/Attic escrow is exactly as unreachable
# inside the namespace as GitHub is. Materialising it into a local proof
# replica BEFORE isolation is what makes the claim honest -- and this group
# runs that path against a real HTTP binary cache rather than asserting it.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  skipped (python3 not on PATH; it serves the throwaway HTTP cache)"
else
  HTTPLOG=$WORK/http-cache.log
  PORTFILE=$WORK/http-cache.port
  rm -f "$PORTFILE"
  # The port comes from a file the helper writes atomically, not from scraping
  # http.server's startup sentence out of a redirected stdout. That is how this
  # group failed in CI: the log was empty because the line was still in a stdio
  # buffer, the test timed out, and t16.2-t16.8 never ran at all -- so the whole
  # remote-escrow path was recorded as unverified on the strength of a
  # buffering artefact.
  python3 "$ROOT/tests/helpers/http-cache-server.py" "$ESCROW/cache" "$PORTFILE" \
    >"$HTTPLOG" 2>&1 &
  HTTP_PID=$!
  # shellcheck disable=SC2064  # $HTTP_PID must expand now, not at trap time
  trap "kill $HTTP_PID 2>/dev/null || :" EXIT
  PORT=""
  for _ in $(seq 1 100); do
    [ -s "$PORTFILE" ] && { PORT=$(cat "$PORTFILE"); break; }
    kill -0 "$HTTP_PID" 2>/dev/null || break
    sleep 0.1
  done
  if [ -z "$PORT" ] || ! curl -sf -m 5 "http://127.0.0.1:$PORT/nix-cache-info" >/dev/null; then
    bad "t16.1 a throwaway HTTP binary cache is serving the escrow" \
      "port='${PORT:-none}'; see $HTTPLOG"
  else
    ok "t16.1 a throwaway HTTP binary cache is serving the escrow"
    REMOTE=$WORK/remote
    rm_store "$REMOTE"; mkdir -p "$REMOTE/evidence"
    for f in manifest.json closure.json discovery.json; do
      command cp -f "$ESCROW/$f" "$REMOTE/$f"
    done
    rc=0
    "$NSE" test-origin-independence "$FIXTURE" \
      --escrow-dir "$REMOTE" \
      --escrow-substituter "http://127.0.0.1:$PORT" \
      >"$WORK/remote.log" 2>&1 || rc=$?
    REMOTE_OI=$REMOTE/evidence/origin-independence.json
    assert_eq "t16.2 the acceptance test passes against a remote escrow" "0" "$rc"
    assert_eq "t16.3 the durable escrow is recorded as the http one" \
      "http://127.0.0.1:$PORT" "$(jq -r '.replaySource.durableEscrow' "$REMOTE_OI")"
    assert_eq "t16.4 but the test replayed from a LOCAL store" \
      "true" "$(jq -r '.replaySource.escrowUsedByTest | startswith("file://")' "$REMOTE_OI")"
    assert_eq "t16.5 and says so: the replica was materialised, not reachable" \
      "materialised" "$(jq -r '.replaySource.escrowMode' "$REMOTE_OI")"
    assert_eq "t16.6 every escrowed object was materialised before isolation" \
      "true" "$(jq -r --slurpfile c "$ESCROW/closure.json" '.replaySource.escrowObjects == ($c[0].escrowPaths|length)' "$REMOTE_OI")"
    assert_eq "t16.7 origins were still unreachable during the run" \
      "0" "$(jq -r '.reachableOriginCount' "$REMOTE_OI")"
    assert_eq "t16.8 a file:// escrow is used directly, with no pointless copy" \
      "direct" "$(jq -r '.replaySource.escrowMode' "$OI")"
  fi
  kill "$HTTP_PID" 2>/dev/null || :
  trap - EXIT
fi

# ---------------------------------------------------------------------------
head_ "t17  every piece of evidence is bound to the code that produced it"
for f in environment.json verify.json trust.json origin-independence.json; do
  assert_eq "t17.1 $f records the revision it was produced on" \
    "true" "$(jq -r '(.provenance.toolRevision // "") | test("^[0-9a-f]{40}$")' "$ESCROW/evidence/$f")"
done
assert_eq "t17.2 and whether the working tree was dirty at the time" \
  "boolean" "$(jq -r '.provenance.workingTreeDirty | type' "$ESCROW/evidence/origin-independence.json")"
assert_eq "t17.3 the acceptance evidence is bound to the manifest it judged" \
  "$(sha256sum "$MANIFEST" | cut -d' ' -f1)" \
  "$(jq -r '.provenance.manifestSha256' "$ESCROW/evidence/origin-independence.json")"
assert_eq "t17.4 the report prints the commit, so a pasted report is traceable" \
  "1" "$(grep -c '^TOOL_COMMIT=' "$REPORT")"

# ---------------------------------------------------------------------------
head_ "t18  a claim the harness cannot model is MODE_UNSUPPORTED, not FAIL"
# Deterministic trigger: prove a guarantee against an escrow that was preserved
# for a different one. The path sets on disk do not correspond to the claim, so
# no build outcome would mean what the verdict says. (This replaces the old
# trigger -- "the approved cache lacks a signed path" -- which was a data
# condition a real build can resolve by building the thing, not something the
# harness is unable to model.)
MISMATCH=$WORK/mismatch
rm_store "$MISMATCH"; mkdir -p "$MISMATCH/evidence"
for f in manifest.json closure.json discovery.json; do
  command cp -f "$ESCROW/$f" "$MISMATCH/$f"
done
rc=0
"$NSE" test-origin-independence "$FIXTURE" \
  --escrow-dir "$MISMATCH" \
  --escrow-substituter "file://$ESCROW/cache" \
  --guarantee source-origin-independence >"$WORK/mismatch.log" 2>&1 || rc=$?
MM_OI=$MISMATCH/evidence/origin-independence.json
assert_ne "t18.1 the run does not exit 0" "0" "$rc"
assert_eq "t18.2 the verdict is MODE_UNSUPPORTED, never PASS or FAIL" \
  "MODE_UNSUPPORTED" "$(jq -r '.result' "$MM_OI")"
assert_eq "t18.3 the reason names the mismatch, not the escrow" \
  "true" "$(jq -r '(.reason // "") | test("preserved for")' "$MM_OI")"
assert_eq "t18.4 no build was run for a claim that was unavailable" \
  "1" "$(jq -r '.buildExit' "$MM_OI")"
assert_eq "t18.5 it is refused as a negative control too" \
  "1" "$(nse_expect_fail_rc "$MM_OI")"
assert_eq "t18.6 the connectivity evidence was still collected" \
  "true" "$(jq -r '(.connectivity|length) > 0' "$MM_OI")"

# ---------------------------------------------------------------------------
head_ "t19  the packaged executable knows which revision it is"
# The bug: nse_provenance asked git at runtime, and an installed /nix/store tree
# has no .git (the src filter drops it) and no working tree. Every `nix run`
# would have reported a null revision, and adding git to runtimeDeps treated
# the symptom. The revision is now stamped in at build time -- which only a
# test against the BUILT package can catch.
rc=0
nix build --no-link --print-out-paths "$ROOT#nix-source-escrow" > "$WORK/pkg-path.txt" 2>"$WORK/pkg-build.log" || rc=$?
if [ "$rc" -ne 0 ]; then
  bad "t19.1 the package builds" "see $WORK/pkg-build.log"
else
  ok "t19.1 the package builds"
  PKG=$(head -1 "$WORK/pkg-path.txt")
  assert_eq "t19.2 the build stamped a revision into the package" \
    "true" "$([ -f "$PKG/share/nix-source-escrow/build-info.json" ] && echo true || echo false)"
  PKGDIR=$WORK/pkg-escrow
  rm_store "$PKGDIR"; mkdir -p "$PKGDIR"
  "$PKG/bin/nix-source-escrow" env --escrow-dir "$PKGDIR" >"$WORK/pkg-env.log" 2>&1
  PKGENV=$PKGDIR/evidence/environment.json
  assert_ne "t19.3 the packaged run records a revision, not null" \
    "null" "$(jq -r '.provenance.toolRevision' "$PKGENV")"
  assert_eq "t19.4 and says it came from the flake, not from a git checkout" \
    "flake" "$(jq -r '.provenance.revisionSource' "$PKGENV")"
  assert_eq "t19.5 the report prints a resolvable TOOL_COMMIT" \
    "0" "$("$PKG/bin/nix-source-escrow" report --escrow-dir "$PKGDIR" 2>/dev/null \
           | grep -c '^TOOL_COMMIT=unknown')"

  # "there is some SHA in there" is too human a check for a file whose whole
  # job is binding a result to a revision. This is the stated acceptance rule
  # for new evidence, so it is asserted rather than left to a reviewer.
  EXPECTED_REV=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo no-git)
  if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "  note: the working tree is DIRTY, so the package cannot name the tested"
    echo "        HEAD -- it reports <rev>-dirty. Commit before producing evidence;"
    echo "        t19.6 and t19.7 are the acceptance rule, not a nit."
  fi
  assert_eq "t19.6 the packaged revision is the exact tested HEAD" \
    "$EXPECTED_REV" "$(jq -r '.provenance.toolRevision' "$PKGENV")"
  assert_eq "t19.7 and the source it was built from was clean" \
    "false" "$(jq -r '.provenance.workingTreeDirty' "$PKGENV")"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1mRESULT\033[0m  passed=%d failed=%d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf 'failed tests:\n'; printf '  - %s\n' "${failed_names[@]}"
  exit 1
fi
