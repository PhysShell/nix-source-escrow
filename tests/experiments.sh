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
#   E0  control: the current defaults. If this does not PASS, the escrow or the
#       harness is broken and NOTHING below it can be attributed to a
#       hypothesis -- so E1..E3 are not even run, and are recorded
#       INCONCLUSIVE rather than REFUTED. A broken escrow makes every variant
#       fail, and calling that "REFUTED" would be the most confident wrong
#       answer this repository could produce.
#
#   E1  substitute=true, no dummy interface
#       Nix disables all substituters -- including file:// ones -- when it
#       decides the machine is offline, UNLESS `substitute` is an explicit
#       override (src/nix/main.cc). prove.sh now sets `substitute = true`, so
#       the dummy route-to-nowhere interface (DESIGN.md §8) should be dead
#       weight. If E1 is CONFIRMED, delete it.
#
#   E2  native flake-input restore
#       prove.sh pre-copies locked flake inputs out of the escrow. Nix should
#       do that itself: Input::getAccessorUnchecked computes the store path
#       from the lock's narHash and calls ensurePath. If E2 is CONFIRMED, the
#       manual copy is a *diagnostic*, and the primary acceptance path should
#       exercise the mechanism a real consumer uses.
#
#   E3  both at once -- the proposed post-v0.1 default. E3 only answers the
#       composition question when E1 and E2 are each CONFIRMED on their own;
#       otherwise its result cannot be attributed to the combination and it is
#       INCONCLUSIVE whatever it did.
#
# The escrow itself is never rebuilt: each run points at the existing cache
# through --escrow-substituter and keeps its evidence in its own directory.
# That is only possible because PROVE no longer assumes it owns the storage.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ---------------------------------------------------------------------------
# Classification. A pure function, so tests/unit-shell.sh can check the rules
# without running a single build.
#
#   nse_experiment_outcome <id> <result> <e0-outcome> <e1-outcome> <e2-outcome>
#     -> "<OUTCOME>\t<reason>"
# ---------------------------------------------------------------------------
nse_experiment_outcome() {
  local id=$1 result=$2 e0=$3 e1=${4:-} e2=${5:-}

  if [ "$id" = E0 ]; then
    case $result in
      PASS) printf 'BASELINE_OK\tthe current defaults still pass, so the variants below are attributable\n' ;;
      *)    printf 'BASELINE_FAILED\tthe current defaults did not pass (%s); nothing can be attributed to a hypothesis until this is green\n' "$result" ;;
    esac
    return 0
  fi

  if [ "$e0" != BASELINE_OK ]; then
    printf 'INCONCLUSIVE\tnot run: the E0 baseline did not pass, so a failure here would say nothing about this hypothesis\n'
    return 0
  fi

  if [ "$id" = E3 ] && { [ "$e1" != CONFIRMED ] || [ "$e2" != CONFIRMED ]; }; then
    printf 'INCONCLUSIVE\tE3 tests the composition of E1 and E2; at least one of them is not established on its own (E1=%s, E2=%s)\n' "$e1" "$e2"
    return 0
  fi

  case $result in
    PASS) printf 'CONFIRMED\tthe workaround was not needed\n' ;;
    FAIL) printf 'REFUTED\tthe build failed without the workaround, with the baseline green\n' ;;
    *)    printf 'INCONCLUSIVE\tthe run ended in %s, which is a statement about the harness or the mode, not about this hypothesis\n' "$result" ;;
  esac
}

# Sourced by the unit tests: definitions only, no runs.
[ "${NSE_EXPERIMENTS_LIB_ONLY:-0}" = 1 ] && return 0

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
: > "$OUT/results.jsonl"

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

E0_OUTCOME=""; E1_OUTCOME=""; E2_OUTCOME=""

record() {  # record <id> <desc> <outcome> <reason> <result> <exit> [oi-file]
  local id=$1 desc=$2 outcome=$3 reason=$4 result=$5 rc=$6 oi=${7:-}
  local colour=33
  case $outcome in
    BASELINE_OK|CONFIRMED) colour=32 ;;
    REFUTED)               colour=33 ;;
    *)                     colour=31 ;;
  esac
  # Progress goes to stderr: stdout carries the outcome word and nothing else,
  # because the caller captures it.
  printf '  \033[%sm%s\033[0m %s\n' "$colour" "$outcome" "$reason" >&2
  if [ -n "$oi" ] && [ -f "$oi" ]; then
    jq -n --arg id "$id" --arg desc "$desc" --arg outcome "$outcome" \
          --arg reason "$reason" --arg result "$result" --argjson exit "$rc" \
          --slurpfile oi "$oi" \
      '{id:$id, description:$desc, outcome:$outcome, outcomeReason:$reason,
        result:$result, exitCode:$exit, ran:true,
        provenance:$oi[0].provenance,
        verdictReason:$oi[0].reason,
        dummyInterface:$oi[0].dummyInterface,
        flakeInputRestore:$oi[0].flakeInputRestore,
        isolationSetup:$oi[0].isolationSetup,
        modeSupported:$oi[0].modeSupported,
        offlineEvalProbe:$oi[0].offlineEvalProbe,
        originHostsProvenUnreachable:$oi[0].originHostsProvenUnreachable}' \
      >> "$OUT/results.jsonl"
  else
    jq -n --arg id "$id" --arg desc "$desc" --arg outcome "$outcome" \
          --arg reason "$reason" --arg result "$result" \
      '{id:$id, description:$desc, outcome:$outcome, outcomeReason:$reason,
        result:(if $result=="" then null else $result end), ran:false}' \
      >> "$OUT/results.jsonl"
  fi
}

run_experiment() {
  local id=$1 desc=$2; shift 2
  printf '\n\033[1m%s\033[0m  %s\n' "$id" "$desc" >&2

  # E1..E3 are not run at all when the baseline is not green: a variant that
  # fails for the same reason the baseline failed is not evidence.
  if [ "$id" != E0 ] && [ "$E0_OUTCOME" != BASELINE_OK ]; then
    local out reason
    IFS=$'\t' read -r out reason < <(nse_experiment_outcome "$id" "" "$E0_OUTCOME" "$E1_OUTCOME" "$E2_OUTCOME")
    record "$id" "$desc" "$out" "$reason" "" 0
    printf '%s' "$out"
    return 0
  fi

  local d=$OUT/$id
  mk_probe_dir "$d"
  local rc=0
  "$NSE" test-origin-independence "$FIXTURE" \
    --escrow-dir "$d" \
    --escrow-substituter "file://$ESCROW/cache" \
    "$@" > "$d/run.log" 2>&1 || rc=$?

  local oi=$d/evidence/origin-independence.json result
  if [ -f "$oi" ]; then result=$(jq -r '.result' "$oi"); else result=NO_RESULT_FILE; oi=""; fi

  local out reason
  IFS=$'\t' read -r out reason < <(nse_experiment_outcome "$id" "$result" "$E0_OUTCOME" "$E1_OUTCOME" "$E2_OUTCOME")
  record "$id" "$desc" "$out" "$reason" "$result" "$rc" "$oi"
  printf '%s' "$out"
}

E0_OUTCOME=$(# E0 names the legacy workarounds explicitly rather than relying on defaults.
# The defaults have since moved (E1/E2/E3 came back CONFIRMED on 2.34.7), and an
# experiment whose baseline drifts with the thing it measures answers nothing.
# Written this way it stays re-runnable on any Nix, which is the point: the
# result is established for 2.34.7 and for no other version until tested.
run_experiment E0 "control: the legacy workarounds (dummy interface + manual input restore)" \
  --dummy-interface --manual-input-restore)
E1_OUTCOME=$(run_experiment E1 "no dummy interface; substitute=true is expected to carry it" \
  --no-dummy-interface --manual-input-restore)
E2_OUTCOME=$(run_experiment E2 "no manual input restore; Nix must substitute locked inputs itself" \
  --dummy-interface --native-input-restore)
run_experiment E3 "both dropped: what the tool now ships as its default" \
  --no-dummy-interface --native-input-restore >/dev/null

# A conclusion is only drawn from a CONFIRMED or REFUTED experiment. Anything
# else leaves the question open, and the field says null rather than guessing.
jq -s --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson provenance "$(NSE_ROOT=$ROOT NSE_DIR=$ESCROW bash -c '. '"$ROOT"'/lib/common.sh; nse_provenance')" \
   'def verdict($id): ([.[] | select(.id == $id) | .outcome] | first);
    def stillNeeded($id): (verdict($id) as $o
      | if $o == "CONFIRMED" then false elif $o == "REFUTED" then true else null end);
    {schemaVersion:2, kind:"experiments", timestamp:$ts, provenance:$provenance,
     experiments:.,
     conclusion:{
       baseline: verdict("E0"),
       dummyInterfaceStillNeeded:      stillNeeded("E1"),
       manualInputRestoreStillNeeded:  stillNeeded("E2"),
       combinedDefaultSafe:            (verdict("E3") == "CONFIRMED")}}' \
   "$OUT/results.jsonl" > "$ESCROW/evidence/experiments.json"

printf '\n\033[1mSUMMARY\033[0m  %s\n' "$ESCROW/evidence/experiments.json"
jq -r '.experiments[] | "  \(.id) \(.outcome)  (result=\(.result // "not run"))"' \
  "$ESCROW/evidence/experiments.json"
jq -r '"  dummy interface still needed:      \(.conclusion.dummyInterfaceStillNeeded // "unknown")",
       "  manual input restore still needed: \(.conclusion.manualInputRestoreStillNeeded // "unknown")",
       "  combined default safe:             \(.conclusion.combinedDefaultSafe)",
       "  measured on:                       \(.provenance.gitCommit[0:12] // "unknown")\(if .provenance.gitDirty then " (DIRTY)" else "" end)"' \
  "$ESCROW/evidence/experiments.json"
