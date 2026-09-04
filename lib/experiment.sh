#!/usr/bin/env bash
#
# Rules for reading an experiment's result. Not an experiment: the rules.
#
# `tests/experiments.sh` ran E0-E3 -- "is the dummy interface still needed",
# "is the manual flake-input restore still needed" -- and was retired with the
# mechanisms it toggled (DESIGN.md §17a). These two definitions outlived it,
# because neither is about those three hypotheses:
#
#   nse_experiment_outcome     a FAIL is a refutation only when the baseline is
#                              green. HARNESS_ERROR and MODE_UNSUPPORTED are
#                              never refutations of anything. A composed
#                              hypothesis is inconclusive until its parts hold
#                              on their own.
#
#   NSE_EXPERIMENTS_SUMMARY_JQ how a result is RENDERED, which turned out to be
#                              a place where results go to die quietly.
#
# Any future experiment in this repository should reach for these rather than
# re-derive them, and `u10` and `u17` keep both honest without needing Nix.

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

# How the summary reads the file it just wrote. A separate, named program
# because both halves of it were wrong for eleven runs and nothing said so.
#
#   "measured on: unknown"   -- it read .provenance.gitCommit and
#                               .provenance.gitDirty. Those fields have never
#                               existed; the block beside it says toolRevision
#                               and workingTreeDirty. `// "unknown"` turned a
#                               wrong field name into a plausible statement
#                               about the world.
#
#   "dummy interface still needed: unknown"  -- while the JSON said `false` and
#                               E1 said CONFIRMED. `//` treats FALSE as absent,
#                               so the one field the whole experiment exists to
#                               produce printed "unknown" precisely when the
#                               answer was "no". DESIGN.md §6 warns about this
#                               operator; this is its third victim here.
#
# Both are read with has() now, and a missing revision says so instead of
# saying "unknown".
# shellcheck disable=SC2034,SC2016  # a jq program, used below and by u17
NSE_EXPERIMENTS_SUMMARY_JQ='
def yesno($k):
  if (.conclusion | has($k) | not) then "UNRECORDED"
  elif .conclusion[$k] == null    then "unknown"
  elif .conclusion[$k]            then "yes"
  else                                 "no" end;
def rev:
  if (.provenance | has("toolRevision") | not) then "UNRECORDED"
  elif .provenance.toolRevision == null
    then "NO REVISION (" + (.provenance.revisionSource // "unknown source") + ")"
  else (.provenance.toolRevision[0:12]
        + (if (.provenance | has("workingTreeDirty")) and .provenance.workingTreeDirty
           then " (DIRTY)" else "" end)
        + " [" + (.provenance.revisionSource // "unknown source") + "]")
  end;
  "  dummy interface still needed:      \(yesno("dummyInterfaceStillNeeded"))",
  "  manual input restore still needed: \(yesno("manualInputRestoreStillNeeded"))",
  "  combined default safe:             \(yesno("combinedDefaultSafe"))",
  "  measured on:                       \(rev)",
  "  nix:                               \(.provenance.nixVersion // "UNRECORDED")"'
