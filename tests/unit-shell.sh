#!/usr/bin/env bash
#
# Shell-level unit tests. These are the checks that do NOT need Nix, a network,
# or namespaces, so they run anywhere -- including in a CI container that has
# no Nix at all, and on a laptop before `nix develop` finishes.
#
#   ./tests/unit-shell.sh
#
# tests/run-tests.sh remains the real acceptance suite. This file exists so the
# pure string/URL/batching logic cannot rot silently between full runs.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nse-unit.XXXXXX")
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/report.sh
. "$ROOT/lib/report.sh"

pass=0; fail=0; failed_names=()
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n    %s\n' "$1" "${2:-}"; fail=$((fail+1)); failed_names+=("$1"); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "expected something other than '$2'"; fi; }

# ---------------------------------------------------------------------------
head_ "u01  escrow URLs are parsed, not assumed to be directories"
assert_eq "u01.1 file:// scheme"   "file"  "$(nse_url_scheme 'file:///srv/escrow?compression=zstd')"
assert_eq "u01.2 s3:// scheme"     "s3"    "$(nse_url_scheme 's3://my-bucket?region=eu-west-1')"
assert_eq "u01.3 https:// scheme"  "https" "$(nse_url_scheme 'https://cache.example.com/team')"
assert_eq "u01.4 bare path counts as file" "file" "$(nse_url_scheme '/srv/escrow')"
assert_eq "u01.5 file:// path strips the query" \
  "/srv/escrow" "$(nse_url_file_path 'file:///srv/escrow?compression=zstd')"
assert_eq "u01.6 query stripping leaves other URLs alone" \
  "https://cache.example.com/team" "$(nse_url_strip_query 'https://cache.example.com/team')"
assert_eq "u01.7 is-file is true only for file backends" \
  "yes no" \
  "$(nse_url_is_file 'file:///a' && printf yes || printf no; printf ' '; nse_url_is_file 'https://a/' && printf yes || printf no)"

head_ "u02  backend names are derived from the URL, never hardcoded"
assert_eq "u02.1 file"  "local-file-binary-cache" "$(nse_backend_name 'file:///srv/e')"
assert_eq "u02.2 s3"    "s3-binary-cache"         "$(nse_backend_name 's3://bucket')"
assert_eq "u02.3 https" "http-binary-cache"       "$(nse_backend_name 'https://attic.example/team')"
assert_eq "u02.4 ssh-ng" "remote-nix-store"       "$(nse_backend_name 'ssh-ng://builder')"

# ---------------------------------------------------------------------------
head_ "u03  presence is a set operation, never one process per path"
CACHE=$TMP/cache; mkdir -p "$CACHE"
: > "$CACHE/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo"
: > "$CACHE/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.narinfo"
present=$(printf '%s\n' \
  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-src \
  /nix/store/cccccccccccccccccccccccccccccccc-missing \
  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other \
  | nse_store_present "file://$CACHE")
assert_eq "u03.1 only the objects the cache holds come back" \
  "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-src
/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other" "$present"
assert_eq "u03.2 an empty input is not an error" "0" \
  "$(printf '' | nse_store_present "file://$CACHE" | wc -l)"

# ---------------------------------------------------------------------------
head_ "u04  batching: no ARG_MAX bomb, no process per path"
seq 1 1000 | sed 's|^|/nix/store/path-|' > "$TMP/paths.txt"
: > "$TMP/calls.log"
# Stand in for `nix`: record one line per invocation and how many paths it got.
# shellcheck disable=SC2317  # called indirectly, through nse_nix_batched
nse_nix() {
  local a n=0
  for a in "$@"; do case $a in /nix/store/*) n=$((n+1)) ;; esac; done
  printf '%d\n' "$n" >> "$TMP/calls.log"
}
# shellcheck disable=SC2034  # read by nse_nix_batched in lib/common.sh
NSE_BATCH_SIZE=256
nse_nix_batched "$TMP/paths.txt" copy --to file:///dev/null
assert_eq "u04.1 1000 paths become 4 invocations, not 1000" "4" "$(wc -l < "$TMP/calls.log")"
assert_eq "u04.2 every path was passed exactly once" \
  "1000" "$(awk '{s+=$1} END{print s}' "$TMP/calls.log")"
assert_eq "u04.3 the last batch is the remainder" "232" "$(tail -1 "$TMP/calls.log")"
: > "$TMP/calls.log"
: > "$TMP/empty.txt"
nse_nix_batched "$TMP/empty.txt" copy --to file:///dev/null
assert_eq "u04.4 an empty set runs nothing at all" "0" "$(wc -l < "$TMP/calls.log")"
# A failing batch must stop the run rather than reporting success.
# shellcheck disable=SC2317  # called indirectly, through nse_nix_batched
nse_nix() { return 1; }
rc=0; nse_nix_batched "$TMP/paths.txt" copy --to file:///dev/null || rc=$?
assert_ne "u04.5 a failing batch is not swallowed" "0" "$rc"
unset -f nse_nix

# ---------------------------------------------------------------------------
head_ "u05  the host in the report is measured, never a literal"
host_json=$(nse_detect_host)
assert_eq "u05.1 host detection emits valid JSON" \
  "ok" "$(printf '%s' "$host_json" | jq -e . >/dev/null 2>&1 && echo ok || echo bad)"
assert_ne "u05.2 it is not the hardcoded string this tool used to print" \
  "Windows 11" "$(printf '%s' "$host_json" | jq -r .kind)"
assert_ne "u05.3 it says how it decided" \
  "" "$(printf '%s' "$host_json" | jq -r .method)"
# shellcheck disable=SC2034  # read by nse_detect_host in lib/report.sh
NSE_HOST="a stated host"; host_json=$(nse_detect_host); unset NSE_HOST
assert_eq "u05.4 an operator-supplied host is labelled as such" \
  "NSE_HOST (operator-supplied)" "$(printf '%s' "$host_json" | jq -r .method)"

# ---------------------------------------------------------------------------
head_ "u06  a report is still produced when there is (almost) nothing to say"
NSE_DIR=$TMP/empty-escrow; export NSE_DIR
mkdir -p "$NSE_DIR/evidence"
rc=0; nse_report > "$TMP/report-empty.txt" 2>&1 || rc=$?
assert_ne "u06.1 a report with no evidence at all refuses" "0" "$rc"
assert_eq "u06.2 and says why, in the report file" \
  "1" "$(grep -c 'REPORT=INSUFFICIENT_STATE' "$NSE_DIR/evidence/report.txt")"

# environment.json alone must be enough for a partial report: a run that died
# in preserve is exactly when the report matters.
NSE_DIR=$TMP/partial-escrow; export NSE_DIR
mkdir -p "$NSE_DIR/evidence"
jq -n '{schemaVersion:2, kind:"environment", nixVersion:"nix (Nix) 9.9.9", system:"x86_64-linux",
        kernel:"Linux 0", os:"TestOS", host:{kind:"test host", method:"fixture"},
        wsl2:false, clientIsTrustedUser:true,
        nixConfig:{experimentalFeatures:"", substituters:"", requireSigs:"true",
                   sandbox:"true", hashedMirrors:""}}' \
  > "$NSE_DIR/evidence/environment.json"
rc=0; nse_report > "$TMP/report-partial.txt" 2>&1 || rc=$?
assert_eq "u06.3 a partial report is produced, not an abort" "0" "$rc"
assert_eq "u06.4 stages that did not run say so" "1" \
  "$(grep -c '^DISCOVERY=NOT_RUN$' "$NSE_DIR/evidence/report.txt")"
assert_eq "u06.5 the acceptance verdict is NOT_RUN, never a silent PASS" "1" \
  "$(grep -c '^ORIGIN_INDEPENDENCE=NOT_RUN$' "$NSE_DIR/evidence/report.txt")"
assert_eq "u06.6 the measured host is printed" "1" \
  "$(grep -c '^HOST=test host$' "$NSE_DIR/evidence/report.txt")"

# ---------------------------------------------------------------------------
head_ "u08  a FAILED pipeline still produces a report"
# The v0.1 CLI ran the stages under `set -e`, so a `nse_prove` that returned 1
# killed the process before `nse_report` ever ran: the report vanished exactly
# when it was needed. Both failure shapes are covered -- a stage that RETURNS
# non-zero, and a stage that calls nse_die (which exits).
export ROOT
FIXTURE_ENV=$TMP/partial-escrow/evidence/environment.json; export FIXTURE_ENV

run_pipeline() {  # run_pipeline <escrow-dir> <failing-stage> <how>
  local dir=$1 stage=$2 how=$3
  mkdir -p "$dir/evidence"
  NSE_DIR=$dir NSE_EXPECT=pass NSE_FAIL_STAGE=$stage NSE_FAIL_HOW=$how \
    bash -c '
      set -euo pipefail
      . "$ROOT/lib/common.sh"
      . "$ROOT/lib/report.sh"
      maybe_fail() {
        [ "$1" = "$NSE_FAIL_STAGE" ] || return 0
        case $NSE_FAIL_HOW in
          return) return 1 ;;
          die)    nse_die "simulated failure in $1" ;;
        esac
      }
      nse_env()         { cp "$FIXTURE_ENV" "$NSE_DIR/evidence/environment.json"; maybe_fail env; }
      nse_discover()    { maybe_fail discover; }
      nse_preserve()    { maybe_fail preserve; }
      nse_verify()      { maybe_fail verify; }
      nse_trust_probe() { maybe_fail trust-probe; }
      nse_prove()       { maybe_fail prove; }
      nse_escrow_pipeline
    ' >/dev/null 2>&1
}

rc=0; run_pipeline "$TMP/pipe-prove" prove return || rc=$?
assert_ne "u08.1 a failing acceptance test makes the pipeline exit non-zero" "0" "$rc"
assert_eq "u08.2 and the report is written anyway" \
  "ok" "$([ -f "$TMP/pipe-prove/evidence/report.txt" ] && echo ok || echo missing)"
assert_eq "u08.3 the report names the pipeline as failed" "1" \
  "$(grep -c '^ESCROW_PIPELINE=FAIL$' "$TMP/pipe-prove/evidence/report.txt")"
assert_eq "u08.4 and names which stage failed" "1" \
  "$(grep -c '^FAILED_STAGES=.*test-origin-independence' "$TMP/pipe-prove/evidence/report.txt")"

rc=0; run_pipeline "$TMP/pipe-die" preserve die || rc=$?
assert_ne "u08.5 a stage that aborts also exits non-zero" "0" "$rc"
assert_eq "u08.6 and a report survives the abort" \
  "ok" "$([ -f "$TMP/pipe-die/evidence/report.txt" ] && echo ok || echo missing)"
assert_eq "u08.7 the aborted run does not claim a verdict" "1" \
  "$(grep -c '^ORIGIN_INDEPENDENCE=NOT_RUN$' "$TMP/pipe-die/evidence/report.txt")"

rc=0; run_pipeline "$TMP/pipe-ok" none return || rc=$?
assert_eq "u08.8 a clean pipeline exits zero" "0" "$rc"
assert_eq "u08.9 and reports the pipeline as passed" "1" \
  "$(grep -c '^ESCROW_PIPELINE=PASS$' "$TMP/pipe-ok/evidence/report.txt")"

# ---------------------------------------------------------------------------
head_ "u09  escrow metadata survives an object that is deliberately broken"
# `nix path-info` refuses a whole batch if one object in it is malformed, which
# would turn "one corrupt narinfo" into "hundreds of objects unclassified".
# For a file:// cache the fields are read as text, so a corrupt object is
# classified as corrupt and its neighbours are unaffected. Test t06 corrupts a
# real escrow and expects exactly that.
META=$TMP/meta-cache; mkdir -p "$META"
mk_narinfo() {  # mk_narinfo <hashpart> <ca-line-or-empty> <sig-line-or-empty>
  { printf 'StorePath: /nix/store/%s-x\nNarSize: 1\n' "$1"
    [ -z "$2" ] || printf '%s\n' "$2"
    [ -z "$3" ] || printf '%s\n' "$3"
  } > "$META/$1.narinfo"
}
mk_narinfo 11111111111111111111111111111111 'CA: fixed:r:sha256:0abc' ''
mk_narinfo 22222222222222222222222222222222 '' 'Sig: cache.nixos.org-1:deadbeef'
mk_narinfo 33333333333333333333333333333333 '' ''
mk_narinfo 44444444444444444444444444444444 'CA: not-a-hash-at-all' ''
meta=$(printf '/nix/store/%s-x\n' 11111111111111111111111111111111 \
       22222222222222222222222222222222 33333333333333333333333333333333 \
       44444444444444444444444444444444 | nse_store_meta "file://$META")
assert_eq "u09.1 one line per path, in order" "4" "$(printf '%s\n' "$meta" | wc -l)"
assert_eq "u09.2 content-addressed object reports its CA verbatim" \
  "fixed:r:sha256:0abc" "$(printf '%s\n' "$meta" | awk -F'\t' 'NR==1{print $2}')"
assert_eq "u09.3 signed object reports no CA and one signature" \
  " 1" "$(printf '%s\n' "$meta" | awk -F'\t' 'NR==2{print $2" "$3}')"
assert_eq "u09.4 unsigned input-addressed object reports neither" \
  " 0" "$(printf '%s\n' "$meta" | awk -F'\t' 'NR==3{print $2" "$3}')"
assert_eq "u09.5 a garbage CA is returned as text, not dropped" \
  "not-a-hash-at-all" "$(printf '%s\n' "$meta" | awk -F'\t' 'NR==4{print $2}')"
assert_eq "u09.6 a missing narinfo yields an empty CA rather than an error" \
  "1" "$(printf '/nix/store/99999999999999999999999999999999-gone\n' \
         | nse_store_meta "file://$META" | awk -F'\t' '$2=="" && $3==0 {n++} END{print n+0}')"

# ---------------------------------------------------------------------------
head_ "u10  an experiment with a broken baseline concludes nothing"
# The trap: a broken escrow makes E0, E1, E2 and E3 all FAIL, and a naive
# `FAIL -> REFUTED` mapping then writes a confident, entirely false
# "the workaround IS needed" into experiments.json.
# shellcheck disable=SC2034  # read by tests/experiments.sh at source time
NSE_EXPERIMENTS_LIB_ONLY=1
# shellcheck source=./experiments.sh
. "$ROOT/tests/experiments.sh"
unset NSE_EXPERIMENTS_LIB_ONLY
outcome() { nse_experiment_outcome "$@" | cut -f1; }

assert_eq "u10.1 a green control is the baseline" \
  "BASELINE_OK" "$(outcome E0 PASS '')"
assert_eq "u10.2 a red control is not a result about anything" \
  "BASELINE_FAILED" "$(outcome E0 FAIL '')"
assert_eq "u10.3 a control that never isolated is not a baseline either" \
  "BASELINE_FAILED" "$(outcome E0 NOT_ISOLATED '')"
assert_eq "u10.4 with a broken baseline, a failing variant is INCONCLUSIVE, not REFUTED" \
  "INCONCLUSIVE" "$(outcome E1 FAIL BASELINE_FAILED)"
assert_eq "u10.5 and so is a passing one" \
  "INCONCLUSIVE" "$(outcome E2 PASS BASELINE_FAILED)"
assert_eq "u10.6 with a green baseline, PASS confirms the workaround was dead weight" \
  "CONFIRMED" "$(outcome E1 PASS BASELINE_OK)"
assert_eq "u10.7 with a green baseline, FAIL refutes it" \
  "REFUTED" "$(outcome E1 FAIL BASELINE_OK)"
assert_eq "u10.8 a harness error says nothing about the hypothesis" \
  "INCONCLUSIVE" "$(outcome E1 HARNESS_ERROR BASELINE_OK)"
assert_eq "u10.9 an unavailable mode says nothing about it either" \
  "INCONCLUSIVE" "$(outcome E2 MODE_UNSUPPORTED BASELINE_OK)"
assert_eq "u10.10 E3 confirms the composition only when both parts stand alone" \
  "CONFIRMED" "$(outcome E3 PASS BASELINE_OK CONFIRMED CONFIRMED)"
assert_eq "u10.11 E3 with a refuted part answers a different question" \
  "INCONCLUSIVE" "$(outcome E3 PASS BASELINE_OK REFUTED CONFIRMED)"
assert_eq "u10.12 E3 with an inconclusive part likewise" \
  "INCONCLUSIVE" "$(outcome E3 FAIL BASELINE_OK CONFIRMED INCONCLUSIVE)"
assert_eq "u10.13 E3 can still be refuted when both parts stand alone" \
  "REFUTED" "$(outcome E3 FAIL BASELINE_OK CONFIRMED CONFIRMED)"
assert_ne "u10.14 every outcome carries a reason" \
  "" "$(nse_experiment_outcome E1 FAIL BASELINE_FAILED | cut -f2)"

# ---------------------------------------------------------------------------
head_ "u11  every result is bound to the code that produced it"
# "E1 = CONFIRMED" is worthless two commits later if nothing records which
# commit, and whether the tree was dirty at the time.
NSE_ROOT=$ROOT; export NSE_ROOT
prov=$(nse_provenance)
assert_eq "u11.1 provenance is valid JSON" \
  "ok" "$(printf '%s' "$prov" | jq -e . >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "u11.2 it records a full commit id" \
  "true" "$(printf '%s' "$prov" | jq -r '(.gitCommit // "") | test("^[0-9a-f]{40}$")')"
assert_eq "u11.3 and whether the working tree was dirty" \
  "boolean" "$(printf '%s' "$prov" | jq -r '.gitDirty | type')"
assert_eq "u11.4 every provenance field is present, even when unknown" \
  "closureSha256 gitCommit gitDirty manifestSha256 nixVersion" \
  "$(printf '%s' "$prov" | jq -r 'keys | join(" ")')"
NSE_DIR=$TMP/prov-escrow; export NSE_DIR
mkdir -p "$NSE_DIR"; printf '{"a":1}' > "$NSE_DIR/manifest.json"
assert_eq "u11.5 the manifest is hashed when it exists" \
  "true" "$(nse_provenance | jq -r '(.manifestSha256 // "") | test("^[0-9a-f]{64}$")')"
assert_eq "u11.6 and reported as null when it does not" \
  "null" "$(nse_provenance | jq -r '.closureSha256')"

# ---------------------------------------------------------------------------
head_ "u07  no source file smuggles a hardcoded machine identity"
# A comment may name the old bug; an emitted line may not. Anchoring at the
# start of a non-comment line is what separates the two.
offenders=$(grep -REn '^[^#]*HOST=(Windows|macOS|Darwin|Ubuntu|NixOS|Linux)' "$ROOT/lib" "$ROOT/bin" || :)
assert_eq "u07.1 nothing prints a fixed HOST= line" "" "$offenders"

printf '\n\033[1mRESULT\033[0m  passed=%d failed=%d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf 'failed tests:\n'; printf '  - %s\n' "${failed_names[@]}"
  exit 1
fi
