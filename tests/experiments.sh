#!/usr/bin/env bash
#
# Experiments, not assertions.
#
# Two workarounds in prove.sh are believed unnecessary on current Nix. Reading
# the Nix sources says they are; this repository's own rule is that reading is
# not evidence. So each hypothesis gets a run, and the run writes down what
# actually happened.
#
#   nix develop -c ./tests/experiments.sh
#
# It never fails the build. It answers questions:
#
#   E1  substitute=true, no dummy interface
#       Nix disables all substituters -- including file:// ones -- when it
#       decides the machine is offline, UNLESS `substitute` is an explicit
#       override (src/nix/main.cc). prove.sh now sets `substitute = true`, so
#       the dummy route-to-nowhere interface (DESIGN.md §8) should be dead
#       weight. If E1 passes, delete it.
#
#   E2  native flake-input restore
#       prove.sh pre-copies locked flake inputs out of the escrow. Nix should
#       do that itself: Input::getAccessorUnchecked computes the store path
#       from the lock's narHash and calls ensurePath. If E2 passes, the manual
#       copy is a *diagnostic*, and the primary acceptance path should exercise
#       the mechanism a real consumer uses.
#
#   E3  both at once -- the proposed post-v0.1 default.
#
# The escrow itself is never rebuilt: each run points at the existing cache
# through --escrow-substituter and keeps its evidence in its own directory.
# That is only possible because PROVE no longer assumes it owns the storage.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NSE=$ROOT/bin/nix-source-escrow
ESCROW=${NSE_TEST_ESCROW:-$ROOT/escrow}
FIXTURE=${NSE_TEST_FIXTURE:-path:$ROOT/fixture#default}
OUT=$ESCROW/work/experiments

command -v nix >/dev/null || { echo "experiments: nix not on PATH" >&2; exit 2; }
[ -f "$ESCROW/manifest.json" ] || {
  echo "experiments: no escrow at $ESCROW; run 'nix-source-escrow escrow \"$FIXTURE\"' first" >&2
  exit 2
}

rm -rf "$OUT"; mkdir -p "$OUT"

# A probe directory is the evidence half of an escrow: the manifest that says
# what to expect, and nowhere to write except its own evidence/.
mk_probe_dir() {
  local d=$1
  mkdir -p "$d/evidence" "$d/work"
  local f
  for f in manifest.json closure.json discovery.json; do
    command cp -f "$ESCROW/$f" "$d/$f"
  done
}

run_experiment() {
  local id=$1 desc=$2; shift 2
  local d=$OUT/$id
  mk_probe_dir "$d"
  printf '\n\033[1m%s\033[0m  %s\n' "$id" "$desc"
  local rc=0
  "$NSE" test-origin-independence "$FIXTURE" \
    --escrow-dir "$d" \
    --escrow-substituter "file://$ESCROW/cache" \
    "$@" > "$d/run.log" 2>&1 || rc=$?
  local oi=$d/evidence/origin-independence.json
  if [ ! -f "$oi" ]; then
    printf '  \033[31mHARNESS\033[0m no result file; see %s\n' "$d/run.log"
    jq -n --arg id "$id" --arg desc "$desc" \
      '{id:$id, description:$desc, outcome:"HARNESS_ERROR", result:null, reason:"no result file"}' \
      >> "$OUT/results.jsonl"
    return 0
  fi
  local result; result=$(jq -r '.result' "$oi")
  local reason; reason=$(jq -r '.reason // ""' "$oi")
  local outcome
  case $result in
    PASS) outcome=CONFIRMED; printf '  \033[32mCONFIRMED\033[0m the workaround was not needed\n' ;;
    FAIL) outcome=REFUTED;   printf '  \033[33mREFUTED\033[0m   %s\n' "$reason" ;;
    *)    outcome=INCONCLUSIVE; printf '  \033[31mINCONCLUSIVE\033[0m %s: %s\n' "$result" "$reason" ;;
  esac
  jq -n --arg id "$id" --arg desc "$desc" --arg outcome "$outcome" \
        --arg result "$result" --arg reason "$reason" \
        --argjson exit "$rc" --slurpfile oi "$oi" \
    '{id:$id, description:$desc, outcome:$outcome, result:$result,
      reason:(if $reason=="" then null else $reason end), exitCode:$exit,
      dummyInterface:$oi[0].dummyInterface,
      flakeInputRestore:$oi[0].flakeInputRestore,
      isolationSetup:$oi[0].isolationSetup,
      offlineEvalProbe:$oi[0].offlineEvalProbe,
      originHostsProvenUnreachable:$oi[0].originHostsProvenUnreachable}' \
    >> "$OUT/results.jsonl"
}

: > "$OUT/results.jsonl"

run_experiment E0 "control: current defaults (dummy interface + manual input restore)"
run_experiment E1 "no dummy interface; substitute=true is expected to carry it" \
  --no-dummy-interface
run_experiment E2 "no manual input restore; Nix must substitute locked inputs itself" \
  --native-input-restore
run_experiment E3 "both: the proposed post-v0.1 default" \
  --no-dummy-interface --native-input-restore

jq -s --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg nixVersion "$(nix --version)" \
   '{schemaVersion:1, kind:"experiments", timestamp:$ts, nixVersion:$nixVersion,
     experiments:., conclusion:{
       dummyInterfaceStillNeeded:
         ([.[]|select(.id=="E1")|.outcome] | first != "CONFIRMED"),
       manualInputRestoreStillNeeded:
         ([.[]|select(.id=="E2")|.outcome] | first != "CONFIRMED")}}' \
   "$OUT/results.jsonl" > "$ESCROW/evidence/experiments.json"

printf '\n\033[1mSUMMARY\033[0m  %s\n' "$ESCROW/evidence/experiments.json"
jq -r '.experiments[] | "  \(.id) \(.outcome)  (result=\(.result))"' "$ESCROW/evidence/experiments.json"
jq -r '"  dummy interface still needed:      \(.conclusion.dummyInterfaceStillNeeded)",
       "  manual input restore still needed: \(.conclusion.manualInputRestoreStillNeeded)"' \
  "$ESCROW/evidence/experiments.json"
