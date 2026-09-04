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
# shellcheck disable=SC2317,SC2329  # called indirectly, through nse_nix_batched
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
# shellcheck disable=SC2317,SC2329  # called indirectly, through nse_nix_batched
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
printf '/nix/store/%s-x\n' 11111111111111111111111111111111 \
       22222222222222222222222222222222 33333333333333333333333333333333 \
       44444444444444444444444444444444 | nse_store_meta "file://$META" > "$TMP/u09.jsonl"
assert_eq "u09.1 one JSON object per path, in order" "4" "$(wc -l < "$TMP/u09.jsonl")"
assert_eq "u09.2 every line is valid JSON with the agreed keys" \
  "4" "$(jq -c -s '[.[]|select(has("path") and has("ca") and has("sigs"))]|length' "$TMP/u09.jsonl")"
assert_eq "u09.3 content-addressed object reports its CA verbatim" \
  "fixed:r:sha256:0abc" "$(jq -r 'select(.path|test("1111"))|.ca' "$TMP/u09.jsonl")"
assert_eq "u09.4 signed object reports an empty CA and one signature" \
  ' 1' "$(jq -r 'select(.path|test("2222"))|"\(.ca) \(.sigs)"' "$TMP/u09.jsonl")"
assert_eq "u09.5 unsigned input-addressed object reports neither" \
  ' 0' "$(jq -r 'select(.path|test("3333"))|"\(.ca) \(.sigs)"' "$TMP/u09.jsonl")"
assert_eq "u09.6 a garbage CA is returned as text, not dropped" \
  "not-a-hash-at-all" "$(jq -r 'select(.path|test("4444"))|.ca' "$TMP/u09.jsonl")"
assert_eq "u09.7 a missing narinfo yields an empty CA rather than an error" \
  "1" "$(printf '/nix/store/99999999999999999999999999999999-gone\n' \
         | nse_store_meta "file://$META" | jq -s '[.[]|select(.ca=="" and .sigs==0)]|length')"

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
assert_eq "u11.2 a dev checkout reports its HEAD" \
  "true" "$(printf '%s' "$prov" | jq -r '(.toolRevision // "") | test("^[0-9a-f]{40}$")')"
assert_eq "u11.3 and says the revision came from the checkout" \
  "git-checkout" "$(printf '%s' "$prov" | jq -r '.revisionSource')"
assert_eq "u11.4 and whether the working tree was dirty" \
  "boolean" "$(printf '%s' "$prov" | jq -r '.workingTreeDirty | type')"
assert_eq "u11.4a every provenance field is present, even when unknown" \
  "closureSha256 manifestSha256 nixVersion revisionSource toolRevision workingTreeDirty" \
  "$(printf '%s' "$prov" | jq -r 'keys | join(" ")')"

# A packaged build has no .git and no working tree: the revision is stamped in
# at build time and a runtime `git` query there returns nothing, however many
# git binaries are on PATH. That was the bug -- adding git to runtimeDeps
# treated the symptom.
PKG=$TMP/packaged; mkdir -p "$PKG/share/nix-source-escrow"
printf '{"toolRevision":"2c50fde0000000000000000000000000deadbeef","workingTreeDirty":false,"revisionSource":"flake"}' \
  > "$PKG/share/nix-source-escrow/build-info.json"
pkgprov=$(NSE_ROOT=$PKG nse_provenance)
assert_eq "u11.4b a packaged build reports its stamped revision, not nothing" \
  "2c50fde0000000000000000000000000deadbeef" "$(printf '%s' "$pkgprov" | jq -r '.toolRevision')"
assert_eq "u11.4c and says the revision came from the flake" \
  "flake" "$(printf '%s' "$pkgprov" | jq -r '.revisionSource')"
assert_eq "u11.4d a clean packaged build is false, not null (jq // treats false as absent)" \
  "false" "$(printf '%s' "$pkgprov" | jq -r '.workingTreeDirty')"
printf '{"toolRevision":"unknown","workingTreeDirty":null,"revisionSource":"flake"}' \
  > "$PKG/share/nix-source-escrow/build-info.json"
assert_eq "u11.4e a source with no revision at all says so rather than guessing" \
  "null flake-no-revision" \
  "$(NSE_ROOT=$PKG nse_provenance | jq -r '"\(.toolRevision) \(.revisionSource)"')"
NSE_DIR=$TMP/prov-escrow; export NSE_DIR
mkdir -p "$NSE_DIR"; printf '{"a":1}' > "$NSE_DIR/manifest.json"
assert_eq "u11.5 the manifest is hashed when it exists" \
  "true" "$(nse_provenance | jq -r '(.manifestSha256 // "") | test("^[0-9a-f]{64}$")')"
assert_eq "u11.6 and reported as null when it does not" \
  "null" "$(nse_provenance | jq -r '.closureSha256')"

# ---------------------------------------------------------------------------
head_ "u12  an unreadable derivation document is not an empty one"
# Measured on two Nix versions in CI: 2.34.7 emits {version, derivations} and
# 2.24.9 emits a flat map. discover.sh read `.derivations // {}`, so on the flat
# shape it saw ZERO derivations and the whole run went green about nothing.
# The fixtures carry the key form each version really emits. They used to use a
# full path in BOTH, so u12.5 -- which compared only the map LENGTH -- could not
# have gone red on the key defect that was sitting there the whole time.
printf '{"version":4,"derivations":{"a.drv":{"outputs":{"out":{"path":"/p"}}}}}' > "$TMP/env.json"
printf '{"/nix/store/a.drv":{"outputs":{"out":{"path":"/p"}}}}' > "$TMP/flat.json"
printf '{"totally":"different"}' > "$TMP/unk.json"
: > "$TMP/empty.json"
assert_eq "u12.1 the nix 2.34.7 shape is recognised" \
  "envelope" "$(nse_drv_schema "$TMP/env.json")"
assert_eq "u12.2 the nix 2.24.9 shape is recognised" \
  "flat-map" "$(nse_drv_schema "$TMP/flat.json")"
assert_eq "u12.3 an unrecognised shape says unknown, it does not guess" \
  "unknown" "$(nse_drv_schema "$TMP/unk.json")"
assert_eq "u12.4 an empty document says unknown too" \
  "unknown" "$(nse_drv_schema "$TMP/empty.json")"
assert_eq "u12.5 both known shapes normalise to the same map" \
  "1 1" "$(nse_drv_map "$TMP/env.json" | jq -r length) $(nse_drv_map "$TMP/flat.json" | jq -r length)"
# The same map means the same KEYS, not merely the same count. discover.sh
# builds a derivation path as "$storedir/" + key; a key that is already a full
# path produced /nix/store//nix/store/... on every 2.24.9 run.
assert_eq "u12.5a and to the same keys, whichever version wrote it" \
  "a.drv a.drv" \
  "$(nse_drv_map "$TMP/env.json" | jq -r 'keys[]') $(nse_drv_map "$TMP/flat.json" | jq -r 'keys[]')"
assert_eq "u12.5b a key is never a path, so prefixing a store dir is safe" \
  "" "$(nse_drv_map "$TMP/flat.json" | jq -r 'keys[] | select(test("/"))')"
rc=0; nse_drv_map "$TMP/unk.json" >/dev/null 2>&1 || rc=$?
assert_ne "u12.6 an unknown shape REFUSES rather than returning an empty map" "0" "$rc"
rc=0; nse_drv_map "$TMP/empty.json" >/dev/null 2>&1 || rc=$?
assert_ne "u12.7 and so does an empty one" "0" "$rc"

# ---------------------------------------------------------------------------
head_ "u13  a signed object is not mistaken for a content-addressed one"
# The defect: nse_store_meta emitted TSV, a signed object has an EMPTY ca
# field, and `read -r p ca sigs` under IFS=$'\t' collapses `\t\t` because tab
# is IFS whitespace. The signature count landed in `ca`, every signed and
# unsigned object was classified content-addressed, and the trust probe
# reported "skipped" for three of its five cases -- while the composition
# counter in the same report, using awk -F'\t', printed the correct numbers.
SIGC=$TMP/sig-cache; mkdir -p "$SIGC"
mk_ni() { printf 'StorePath: /nix/store/%s-x\n' "$1" > "$SIGC/$1.narinfo"
          [ -z "${2:-}" ] || printf '%s\n' "$2" >> "$SIGC/$1.narinfo"; }
mk_ni aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 'CA: fixed:r:sha256:abc'
mk_ni bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 'Sig: cache.nixos.org-1:deadbeef'
mk_ni cccccccccccccccccccccccccccccccc ''
mk_ni dddddddddddddddddddddddddddddddd 'CA: text:sha256:zzz'
printf '/nix/store/%s-x\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  cccccccccccccccccccccccccccccccc dddddddddddddddddddddddddddddddd \
  | nse_store_meta "file://$SIGC" > "$TMP/meta.jsonl"
assert_eq "u13.1 metadata is JSONL, one object per path" \
  "4" "$(wc -l < "$TMP/meta.jsonl")"
assert_eq "u13.2 a signed object keeps an EMPTY ca and its signature count" \
  '"" 1' "$(jq -r 'select(.path|test("bbbb"))|"\(.ca|tojson) \(.sigs)"' "$TMP/meta.jsonl")"
assert_eq "u13.3 the shared classifier separates all four classes" \
  "ca-fixed signed unsigned ca-text" \
  "$(jq -r "$NSE_JQ_CLASSIFY"' nse_class' "$TMP/meta.jsonl" | paste -sd' ' -)"
assert_eq "u13.4 the trust probe finds a sample of every class it needs" \
  "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-x /nix/store/cccccccccccccccccccccccccccccccc-x" \
  "$(printf '/nix/store/%s-x\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
       cccccccccccccccccccccccccccccccc dddddddddddddddddddddddddddddddd > "$TMP/cands.txt"
     jq -r -n "$NSE_JQ_CLASSIFY"'
       ( [ inputs ] | map({key: .path, value: .}) | from_entries ) as $m
       | ( $order | split("\n") | map(select(length > 0)) ) as $cands
       | def pick($want): [ $cands[] | select( ($m[.] // null) != null
                                               and ($m[.] | nse_class) == $want ) ][0] // "";
         [ pick("signed"), pick("unsigned") ] | .[]
       ' --rawfile order "$TMP/cands.txt" "$TMP/meta.jsonl" | paste -sd' ' -)"

# ---------------------------------------------------------------------------
head_ "u14  no local variable inherits an export from the build environment"
# `local out` does NOT clear the export attribute if the caller exported `out`
# -- and `nix develop` exports $out. A multi-megabyte path-info document then
# travels in the environment of every child, and the next exec dies E2BIG,
# exit 126. That is what killed the entire SOURCE_ORIGIN_INDEPENDENCE run in
# CI, reported as an unexplained red rather than as a harness crash.
assert_eq "u14.1 bash really does keep the export attribute on a local" \
  "declare -x leaky=\"v\"" \
  "$(export leaky=outer; bash -c 'f() { local leaky; leaky=v; declare -p leaky; }; f')"
offenders=$(grep -nE '^\s*local\s+(-[a-zA-Z]+\s+)?(out|src|name|system|builder|args|outputs|pname|version)(\s|=|$)' \
              "$ROOT"/lib/*.sh "$ROOT/bin/nix-source-escrow" || :)
assert_eq "u14.2 no lib function locals a name stdenv exports" "" "$offenders"
# End to end, and the failure mode exactly as it happened -- which the earlier
# form of this test did NOT reproduce. `nix develop` exports a SMALL $out: a
# store path, a hundred bytes. The bug was that `local out` inside
# nse_store_present INHERITED that export attribute, so the multi-hundred-KB
# path-info document the function then assigned to it became an environment
# variable of every child, and the next exec died E2BIG (126).
#
# So the fixture has to put the bulk where the bug put it: in the store's
# ANSWER, not in the caller's environment. A caller that exports a 300KB $out
# itself has already broken exec for everything it runs, us included; that is
# the caller's defect and no parser can survive it.
big=$(python3 - <<'PYEOF'
import json
print(json.dumps({"/nix/store/%s-p" % str(i).rjust(32, "a"): {"narSize": 1}
                  for i in range(4000)}))
PYEOF
)
u14_3="u14.3 fixture is large enough that exec would fail if it were exported"
if [ "${#big}" -gt 200000 ]; then ok "$u14_3"; else bad "$u14_3" "only ${#big} bytes"; fi
rc=0
count=$(
  export out=/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-thing
  . "$ROOT/lib/common.sh"
  # shellcheck disable=SC2317,SC2329  # called indirectly, through nse_store_present
  nse_nix() { printf '%s\n' "$big"; }
  printf '/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-x\n' \
    | nse_store_present "https://example.invalid" | wc -l) || rc=$?
assert_eq "u14.4 a large store answer does not travel in the environment" "0" "$rc"
assert_eq "u14.5 ...and every path it reports is read back" "4000" "$count"

# ---------------------------------------------------------------------------
head_ "u15  a path Nix reports as null is ABSENT, not present"
# The P0 the first source-mode run died of. `nix path-info --json` does not omit
# a path it cannot find and does not fail: it emits `"<path>": null` and exits
# 0. Both measured Nix versions do this. The parser took `keys[]`, so every
# path we ASKED about came back present -- 227 candidates in, 227 "supplied"
# out, including a store path this machine had built minutes earlier that no
# public cache could hold. `nix copy` then went looking for it.
mixed='{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-present":{"narSize":1},
        "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-absent":null,
        "/nix/store/cccccccccccccccccccccccccccccccc-present2":{"narSize":2}}'
assert_eq "u15.1 only the paths with a non-null value come back" \
  "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-present /nix/store/cccccccccccccccccccccccccccccccc-present2" \
  "$(printf '%s' "$mixed" | nse_pathinfo_present_keys | paste -sd' ' -)"
assert_eq "u15.2 the absent one is never reported present" \
  "0" "$(printf '%s' "$mixed" | nse_pathinfo_present_keys | grep -c 'absent' || true)"
assert_eq "u15.3 an all-null answer means nothing is present, not everything" \
  "0" "$(printf '{"/nix/store/dddddddddddddddddddddddddddddddd-x":null}' \
         | nse_pathinfo_present_keys | wc -l)"
assert_eq "u15.4 the array shape is understood too" \
  "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-x" \
  "$(printf '[{"path":"/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-x"}]' | nse_pathinfo_present_keys)"
rc=0; printf '"a bare string"' | nse_pathinfo_present_keys >/dev/null 2>&1 || rc=$?
assert_ne "u15.5 an unrecognised shape FAILS rather than reporting nothing present" "0" "$rc"
rc=0; printf 'not json at all' | nse_pathinfo_present_keys >/dev/null 2>&1 || rc=$?
assert_ne "u15.6 and so does a non-JSON answer" "0" "$rc"
# The end-to-end shape of the defect: a store query must not report a path
# present just because it was asked about.
# shellcheck disable=SC2317,SC2329  # called indirectly, through nse_store_present
nse_nix() { printf '{"/nix/store/ffffffffffffffffffffffffffffffff-asked":null}\n'; }
assert_eq "u15.7 nse_store_present reports nothing present for an all-null answer" \
  "0" "$(printf '/nix/store/ffffffffffffffffffffffffffffffff-asked\n' \
         | nse_store_present "https://example.invalid" | wc -l)"
unset -f nse_nix

# ---------------------------------------------------------------------------
head_ "u16  a derivation's attributes survive both ways of carrying them"
# MEASURED in CI, both shapes taken verbatim from the two Nix versions. A
# derivation with __structuredAttrs = true puts its attributes in
# `structuredAttrs` on 2.34.7 and in the STRING `env.__json` on 2.24.9. Reading
# only the first two places saw {"__json": ..., "out": ...} -- no url, no urls,
# no postFetch -- and filed 17 sources with perfectly good origins under
# "can never be re-fetched upstream". Nothing about that was visible in a
# report: the count simply moved.
# shellcheck disable=SC2031  # u14 sources common.sh in a subshell; this is the outer one
jqattr() { jq -r "$NSE_JQ_DRV_ATTRS $1"; }
printf '%s' '{"name":"hello.tar.gz","env":{"out":"/nix/store/x"},
  "structuredAttrs":{"urls":["https://ftp.gnu.org/h.tar.gz"],"postFetch":"unpack",
                     "stripRoot":true}}' > "$TMP/sa-parsed.json"
printf '%s' '{"name":"hello.tar.gz","env":{"out":"/nix/store/x",
  "__json":"{\"urls\":[\"https://ftp.gnu.org/h.tar.gz\"],\"postFetch\":\"unpack\",\"stripRoot\":true}"}}' \
  > "$TMP/sa-json.json"
printf '%s' '{"name":"plain.patch","env":{"out":"/nix/store/y",
  "url":"https://example.org/p.patch","urls":"https://example.org/p.patch"}}' \
  > "$TMP/sa-env.json"
printf '%s' '{"name":"bootstrap","env":{"out":"/nix/store/z"}}' > "$TMP/sa-none.json"
printf '%s' '{"name":"broken","env":{"out":"/nix/store/w","__json":"{not json"}}' \
  > "$TMP/sa-bad.json"

assert_eq "u16.1 parsed structuredAttrs yields the origin URL" \
  "https://ftp.gnu.org/h.tar.gz" "$(jqattr 'nse_urls_of(.)[]' < "$TMP/sa-parsed.json")"
assert_eq "u16.2 the SAME derivation as env.__json yields the SAME URL" \
  "https://ftp.gnu.org/h.tar.gz" "$(jqattr 'nse_urls_of(.)[]' < "$TMP/sa-json.json")"
assert_eq "u16.3 postFetch is found through env.__json too, so hash mode is right" \
  "unpack unpack" \
  "$(jqattr 'nse_attr(.;"postFetch")' < "$TMP/sa-parsed.json") $(jqattr 'nse_attr(.;"postFetch")' < "$TMP/sa-json.json")"
assert_eq "u16.4 and so is stripRoot, with its type intact" \
  "true true" \
  "$(jqattr 'nse_attr(.;"stripRoot")' < "$TMP/sa-parsed.json") $(jqattr 'nse_attr(.;"stripRoot")' < "$TMP/sa-json.json")"
assert_eq "u16.5 a plain env derivation still works, string urls split" \
  "https://example.org/p.patch" "$(jqattr 'nse_urls_of(.)[]' < "$TMP/sa-env.json")"
assert_eq "u16.6 a derivation with no origin at all reports none" \
  "0" "$(jqattr 'nse_urls_of(.) | length' < "$TMP/sa-none.json")"
rc=0; jqattr 'nse_urls_of(.)' < "$TMP/sa-bad.json" >/dev/null 2>&1 || rc=$?
assert_ne "u16.7 an env.__json that is not JSON FAILS, it is not no attributes" "0" "$rc"

# ---------------------------------------------------------------------------
head_ "u17  the experiments summary reads the file it just wrote"
# For eleven runs it printed, side by side:
#     dummy interface still needed:      unknown
#     measured on:                       unknown
# while the JSON it was reading said `false` and carried the exact commit. Two
# separate defects with one operator between them: `//` treats FALSE as absent,
# so the conclusion the whole experiment exists to produce read "unknown"
# exactly when the answer was "no"; and the provenance lines read
# .provenance.gitCommit / .gitDirty, field names that have never existed.
printf '%s' '{"provenance":{"toolRevision":"783bc5a9c8acb71613ac302abf1abb541f4c5823",
  "revisionSource":"git-checkout","workingTreeDirty":false,"nixVersion":"nix (Nix) 2.34.7"},
  "conclusion":{"dummyInterfaceStillNeeded":false,"manualInputRestoreStillNeeded":false,
                "combinedDefaultSafe":true}}' > "$TMP/exp-clean.json"
printf '%s' '{"provenance":{"toolRevision":"783bc5a9c8acb71613ac302abf1abb541f4c5823",
  "revisionSource":"git-checkout","workingTreeDirty":true,"nixVersion":"nix (Nix) 2.24.9"},
  "conclusion":{"dummyInterfaceStillNeeded":null,"manualInputRestoreStillNeeded":true,
                "combinedDefaultSafe":false}}' > "$TMP/exp-dirty.json"
printf '%s' '{"provenance":{"toolRevision":null,"revisionSource":"flake-no-revision"},
  "conclusion":{}}' > "$TMP/exp-norev.json"
expsum() { jq -r "$NSE_EXPERIMENTS_SUMMARY_JQ" "$1" | sed 's/  */ /g;s/^ //'; }

assert_eq "u17.1 a CONFIRMED workaround reads 'no', never 'unknown'" \
  "dummy interface still needed: no" "$(expsum "$TMP/exp-clean.json" | sed -n 1p)"
assert_eq "u17.2 and so does the second one" \
  "manual input restore still needed: no" "$(expsum "$TMP/exp-clean.json" | sed -n 2p)"
assert_eq "u17.3 a true conclusion still reads 'yes'" \
  "manual input restore still needed: yes" "$(expsum "$TMP/exp-dirty.json" | sed -n 2p)"
assert_eq "u17.4 a genuinely unknown conclusion is the ONLY thing that reads 'unknown'" \
  "dummy interface still needed: unknown" "$(expsum "$TMP/exp-dirty.json" | sed -n 1p)"
assert_eq "u17.5 the revision is the one in the file, with its source" \
  "measured on: 783bc5a9c8ac [git-checkout]" "$(expsum "$TMP/exp-clean.json" | sed -n 4p)"
assert_eq "u17.6 a dirty tree is marked, so a result cannot be quietly reattributed" \
  "measured on: 783bc5a9c8ac (DIRTY) [git-checkout]" "$(expsum "$TMP/exp-dirty.json" | sed -n 4p)"
assert_eq "u17.7 the Nix it ran on is printed, not assumed" \
  "nix: nix (Nix) 2.24.9" "$(expsum "$TMP/exp-dirty.json" | sed -n 5p)"
assert_eq "u17.8 no revision says so; it does not borrow the word 'unknown'" \
  "measured on: NO REVISION (flake-no-revision)" "$(expsum "$TMP/exp-norev.json" | sed -n 4p)"
assert_eq "u17.9 a missing conclusion field is UNRECORDED, not a verdict" \
  "combined default safe: UNRECORDED" "$(expsum "$TMP/exp-norev.json" | sed -n 3p)"

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
