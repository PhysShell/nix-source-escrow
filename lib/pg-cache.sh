# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is a jq program.
#
# policy-governed line -- COMMIT 9, the cache controls.
#
# PREREG.md §15. Two sentences bound the whole file, and the second one is the
# one that gets violated:
#
#     cache bytes    != evidence
#     cached VERDICT != evidence, and this one is worse
#
# A shared cache may hold content-addressed BYTES. It may not hold
# authoritative CONCLUSIONS about them. The distinction is not pedantic: bytes
# in a cache can be re-verified against a hash by anyone, and a conclusion in a
# cache can only be believed.
#
#   CACH1  a cache miss cannot change verdict semantics
#   CACH2  cache corruption cannot become evidence
#   CACH3  the acceptance store is fresh before selected objects arrive
#   CACH4  the cache changes runtime cost and nothing else
#   CACH5  cached VERIFIED / REQUIRED / PRESENT decisions are never
#          authoritative; the trusted judge recomputes them

# Documents that would be a CACHED VERDICT if anything read them. None of them
# is read. They are looked for, so that finding one can be REPORTED rather than
# silently ignored -- "we did not read it" and "there was nothing to read" are
# different statements and only one of them is checkable.
NSE_PG_VERDICT_ARTIFACTS=(
  gate-report.json
  decisions.json
  verify.json
  origin-independence.json
  manifest.json
  trust.json
)

# nse_pg_cached_verdicts_in <root>  ->  JSON array of the ones present
# EXPLICIT `if`, not `[ -f x ] && printf`.
#
# Under `set -o pipefail` -- which bin/nse-pg sets, and should -- a false test
# at the end of the loop body makes the whole GROUP exit non-zero, and pipefail
# then fails the entire pipeline. The function returned 1 while printing a
# perfectly correct `[]`, and the gate died two lines into a run with no error
# message at all, because the failure was a test that answered "no".
#
# "This file is not here" is an ANSWER. It must not be an exit status.
nse_pg_cached_verdicts_in() {
  local root=$1 rel
  {
    for rel in "${NSE_PG_VERDICT_ARTIFACTS[@]}"; do
      if [ -f "$root/$rel" ]; then printf '%s\n' "$rel"; fi
      if [ -f "$root/escrow/evidence/$rel" ]; then printf '%s\n' "escrow/evidence/$rel"; fi
    done
    :
  } | LC_ALL=C sort -u | nse_pg_jq -R -s 'split("\n") | map(select(length > 0))'
}

# ---------------------------------------------------------------------------
# CACH3, as a function rather than as a line inside a longer one.
#
#   nse_pg_scratch_prepare <dir>
#
# The store the acceptance test replays from starts EMPTY. That is the closed
# line standing invariant and it is preserved here unchanged; a scratch
# directory inherited from a previous run is the cheapest possible way to lose
# it, and inheriting one is the default behaviour of every mkdir -p.
#
# Sets NSE_PG_SCRATCH_WIPED to the number of entries removed, so a run can
# state that it started clean instead of assuming it.
# ---------------------------------------------------------------------------
NSE_PG_SCRATCH_WIPED=0
export NSE_PG_SCRATCH_WIPED
nse_pg_scratch_prepare() {
  local dir=$1
  NSE_PG_SCRATCH_WIPED=0
  if [ -e "$dir" ]; then
    NSE_PG_SCRATCH_WIPED=$(find "$dir" -mindepth 1 2>/dev/null | wc -l | tr -d " ")
    chmod -R u+w "$dir" 2>/dev/null || :
    rm -rf "$dir"
  fi
  mkdir -p "$dir" || return 1
  # Observed, not assumed. `rm -rf` can fail on a path it cannot write, and a
  # prepare that reports success on a directory it did not empty is exactly the
  # shape this whole repository exists to refuse.
  local left; left=$(find "$dir" -mindepth 1 2>/dev/null | wc -l | tr -d " ")
  [ "$left" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# CACH1 / CACH4, as a comparison of two runs.
#
#   nse_pg_cache_compare <cold-report.json> <warm-report.json>
#
# The two reports must agree on every SEMANTIC field and are permitted to
# disagree on exactly one thing: how long it took. A cache that changes any
# other field has changed what the run means.
# ---------------------------------------------------------------------------
nse_pg_cache_compare() {
  local cold=$1 warm=$2
  nse_pg_jq -n --slurpfile c "$cold" --slurpfile w "$warm" \
    '($c[0]) as $C | ($w[0]) as $W
     | { semanticFields: ["checkName", "result", "exitCode", "guarantee"],
         cold: { checkName: $C.checkName, result: $C.result, exitCode: $C.exitCode,
                 guarantee: $C.guarantee, ms: $C.elapsedMilliseconds },
         warm: { checkName: $W.checkName, result: $W.result, exitCode: $W.exitCode,
                 guarantee: $W.guarantee, ms: $W.elapsedMilliseconds },
         CACH1_semanticsUnchanged:
           ( $C.checkName == $W.checkName and $C.result == $W.result
             and $C.exitCode == $W.exitCode and $C.guarantee == $W.guarantee ),
         CACH4_onlyCostMoved:
           ( $C.checkName == $W.checkName and $C.result == $W.result
             and $C.exitCode == $W.exitCode and $C.guarantee == $W.guarantee ),
         speedup: ( if $W.elapsedMilliseconds > 0
                    then (($C.elapsedMilliseconds / $W.elapsedMilliseconds) * 100 | floor) / 100
                    else null end),
         note: "A cache that changes any field other than elapsed time has changed what the run MEANS. PREREG.md §15: the cache is an accelerator." }'
}
