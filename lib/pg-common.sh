# shellcheck shell=bash
#
# policy-governed line -- shared plumbing.
#
# Sourced by bin/nse-pg. Not executable on its own.

# Exit codes, so that a caller can tell the three states apart. PREREG.md §17.1:
# a checker error is its OWN failure state, and must never be able to arrive as
# a PASS or as an empty FAIL.
NSE_PG_OK=0
NSE_PG_FAIL=1
NSE_PG_USAGE=2
NSE_PG_CHECKER_ERROR=3
export NSE_PG_OK NSE_PG_FAIL NSE_PG_USAGE NSE_PG_CHECKER_ERROR

nse_pg_log()  { printf '==> %s\n' "$*" >&2; }
nse_pg_step() { printf '\n=== %s ===\n' "$*" >&2; }
nse_pg_warn() { printf 'nse-pg: warning: %s\n' "$*" >&2; }
nse_pg_fail() { printf 'nse-pg: FAIL: %s\n' "$*" >&2; exit "$NSE_PG_FAIL"; }

# CHECKER_ERROR. Distinct from FAIL on purpose and at the exit-code level:
# "the check says no" and "the check could not run" are different results, and
# a harness that renders them the same colour has one fewer state than reality.
nse_pg_checker_error() {
  printf 'nse-pg: CHECKER_ERROR: %s\n' "$*" >&2
  exit "$NSE_PG_CHECKER_ERROR"
}

# ---------------------------------------------------------------------------
# jq, with its stderr treated as a result rather than as decoration.
#
# PREREG.md §17.1, and the reason it is a rule rather than a habit: jq exits 5
# on a program error, but a caller writing
#
#     n=$(jq -r '.someTypo' doc.json)
#
# inside `$( )` gets the empty string and a status nobody looked at, and the
# empty string then reads as "zero of them" -- the same defect as an unreadable
# document reading as an empty one, one layer further out.
#
# So: stderr is captured, a non-empty stderr is a CHECKER FAILURE, and there is
# no path from here to an empty or negative result.
#
#     nse_pg_jq <jq args...>     stdin/stdout as usual
# ---------------------------------------------------------------------------
nse_pg_jq() {
  # NOT `local out`. `local` does not clear the EXPORT attribute a caller put on
  # a name, and `nix develop` exports $out -- so a jq answer assigned to a local
  # called `out` becomes an environment variable of every subsequent child, and
  # the next exec dies E2BIG. That is not hypothetical: it killed a whole
  # SOURCE_ORIGIN_INDEPENDENCE run in the closed line and was reported as an
  # unexplained red rather than as a harness crash. u14 in tests/unit-shell.sh
  # is the guard, and it caught this file.
  local err answer rc=0
  err=$(mktemp "${TMPDIR:-/tmp}/nse-pg-jq.XXXXXX") || nse_pg_checker_error "mktemp failed"
  answer=$(jq "$@" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    nse_pg_checker_error "jq exited $rc. stderr: $(tr '\n' ' ' < "$err" | head -c 600)"
  fi
  if [ -s "$err" ]; then
    local msg; msg=$(tr '\n' ' ' < "$err" | head -c 600)
    rm -f "$err"
    nse_pg_checker_error "jq wrote to stderr while exiting 0, which is not a
       result this line accepts as empty: $msg"
  fi
  rm -f "$err"
  printf '%s\n' "$answer"
}

# Same contract, for a boolean test. A jq -e that cannot run is a CHECKER_ERROR;
# only a jq -e that RAN and said false is a false.
#
# jq -e exits 1 for false/null and 5 for a program error, so the two are
# distinguishable -- but only by a caller that looks, which is what this is for.
nse_pg_jq_test() {
  local err rc=0
  err=$(mktemp "${TMPDIR:-/tmp}/nse-pg-jqt.XXXXXX") || nse_pg_checker_error "mktemp failed"
  jq -e "$@" >/dev/null 2>"$err" || rc=$?
  case $rc in
    0|1) : ;;
    *) local msg; msg=$(tr '\n' ' ' < "$err" | head -c 600); rm -f "$err"
       nse_pg_checker_error "jq -e exited $rc (a program error, not a false): $msg" ;;
  esac
  if [ -s "$err" ]; then
    local msg; msg=$(tr '\n' ' ' < "$err" | head -c 600); rm -f "$err"
    nse_pg_checker_error "jq -e wrote to stderr: $msg"
  fi
  rm -f "$err"
  return "$rc"
}

# Deterministic JSON out, atomically written in. Same two helpers the closed
# line uses, addressed through this file so the policy stages do not have to
# source the whole tool to write a document.
nse_pg_write_json() {
  local dest=$1 tmp
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp "${dest}.XXXXXX") || nse_pg_checker_error "mktemp failed for $dest"
  jq -S '.' > "$tmp" || { rm -f "$tmp"; nse_pg_checker_error "not valid JSON, refusing to write $dest"; }
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; nse_pg_checker_error "failed installing $dest"; }
}

# A sha256 over a CANONICAL rendering of a JSON value on stdin.
#
# Canonical means: jq -S, compact, one trailing newline. Two documents that
# differ only in key order or whitespace must hash the same, or every digest in
# this line reports churn instead of change -- which is the single-digest
# failure mode PREREG.md §12 exists to avoid, reintroduced at the bottom.
nse_pg_sha256_canonical() {
  # `canonical`, not `out`, for the reason spelled out in nse_pg_jq above.
  local canonical
  canonical=$(nse_pg_jq -S -c '.') || return 1
  printf '%s\n' "$canonical" | sha256sum | cut -d' ' -f1
}
