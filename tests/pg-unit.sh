#!/usr/bin/env bash
#
# Policy-governed line: shell-level units. NO Nix, no network, no namespaces.
#
#   ./tests/pg-unit.sh
#
# This file is separate from tests/unit-shell.sh on purpose. That suite belongs
# to the CLOSED line and must keep passing untouched; this one belongs to the
# policy-governed line. Mixing them would make one experiment's green depend on
# the other's code.
#
# Everything the authority boundary rests on is testable here, without Nix, and
# that is a design constraint rather than a convenience: a gate that can only be
# re-tested with a store and a network is a gate nobody re-tests.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nse-pg-unit.XXXXXX")
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/pg-common.sh
. "$ROOT/lib/pg-common.sh"
# shellcheck source=../lib/pg-facts.sh
. "$ROOT/lib/pg-facts.sh"

pass=0; fail=0; failed_names=()
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n    %s\n' "$1" "${2:-}"; fail=$((fail+1)); failed_names+=("$1"); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "expected something other than '$2'"; fi; }

# ---------------------------------------------------------------------------
# The two derivation-document shapes, written the way NIX writes them.
#
# Not the way it would be convenient to write them. The closed line's fixtures
# once used a key form the real tool emits in NEITHER of its two schemas, and
# every assertion built on them was about a document that does not exist. So
# these carry the real differences, all four of them:
#
#   2.34.7  envelope   {"version":4,"derivations":{...}}   bare object name key
#           attributes in `structuredAttrs`
#   2.24.9  flat map   {...}                               FULL /nix/store path key
#           attributes in `env.__json`, as a STRING of JSON
#
# and they are fed through nse_drv_map, exactly as the real code does, so the
# normalisation is under test too.
# ---------------------------------------------------------------------------
mkdoc_envelope() { # $1 attrs-json -> stdout raw document
  jq -n --argjson attrs "$1" '{
    version: 4,
    derivations: {
      "abcd0000000000000000000000000000-nix-pills-src.drv": {
        name: "nix-pills-src",
        builder: "/nix/store/xxxx-bash/bin/bash",
        outputs: { out: { path: "/nix/store/pppp0000000000000000000000000000-nix-pills-src",
                          hash: "sha256-MIMqNvR3oazdybbVbQv/gF3oY7Tzma6NgRYedJGdqz0=",
                          hashAlgo: "r:sha256", method: "nar" } },
        structuredAttrs: $attrs,
        env: { out: "/nix/store/pppp0000000000000000000000000000-nix-pills-src" }
      } } }'
}
mkdoc_flatmap() { # $1 attrs-json -> stdout raw document
  jq -n --argjson attrs "$1" '{
    "/nix/store/abcd0000000000000000000000000000-nix-pills-src.drv": {
      name: "nix-pills-src",
      builder: "/nix/store/xxxx-bash/bin/bash",
      outputs: { out: { path: "/nix/store/pppp0000000000000000000000000000-nix-pills-src",
                        hash: "sha256-MIMqNvR3oazdybbVbQv/gF3oY7Tzma6NgRYedJGdqz0=",
                        hashAlgo: "r:sha256", method: "nar" } },
      env: { __json: ($attrs | tojson),
             out: "/nix/store/pppp0000000000000000000000000000-nix-pills-src" } } }'
}

DRV=abcd0000000000000000000000000000-nix-pills-src.drv

# Attributes a real fetchFromGitHub-derived FOD would carry IF the names were
# passed through. Whether they actually are is COMMIT 2's measurement, not this
# file's assumption -- these tests qualify the reader, they do not predict Nix.
ATTRS_FULL='{"urls":["https://github.com/NixOS/nix-pills/archive/4df9718.tar.gz"],
             "owner":"NixOS","repo":"nix-pills",
             "rev":"4df971884fa974c49b944ba648f2e48a82404c84",
             "githubBase":"github.com","extension":"tar.gz",
             "stripRoot":true,"postFetch":"unpack"}'
# The same fetch with the names NOT passed through: only what fetchurl always
# has. This is the shape that yields UNKNOWN, and it is half of every red
# control below.
ATTRS_BARE='{"urls":["https://github.com/NixOS/nix-pills/archive/4df9718.tar.gz"],
             "postFetch":"unpack"}'

both_schemas_facts() { # $1 attrs-json ; stdout: two fact objects, one per line
  local a=$1 f
  for f in mkdoc_envelope mkdoc_flatmap; do
    "$f" "$a" > "$TMP/raw.json"
    nse_drv_map "$TMP/raw.json" > "$TMP/map.json" || { echo '{"error":"drv_map failed"}'; continue; }
    nse_pg_facts_of "$TMP/map.json" "$DRV" | jq -c '.'
  done
}

# ---------------------------------------------------------------------------
head_ "p01  a fact is a value AND its provenance, on BOTH document schemas"
mapfile -t full_facts < <(both_schemas_facts "$ATTRS_FULL")
assert_eq "p01.1 two schemas produced two readings" "2" "${#full_facts[@]}"
assert_eq "p01.2 envelope: owner is read from a derivation attribute" \
  "NixOS DERIVATION_ATTR structuredAttrs" \
  "$(printf '%s' "${full_facts[0]}" | jq -r '[.facts.owner.value,.facts.owner.source,.facts.owner.attrSite]|join(" ")')"
assert_eq "p01.3 flat map: the SAME fact, out of env.__json -- and SAYING env.__json" \
  "NixOS DERIVATION_ATTR env.__json" \
  "$(printf '%s' "${full_facts[1]}" | jq -r '[.facts.owner.value,.facts.owner.source,.facts.owner.attrSite]|join(" ")')"
assert_ne "p01.3a the two schemas do NOT claim the same carriage site" \
  "$(printf '%s' "${full_facts[0]}" | jq -r '.facts.owner.attrSite')" \
  "$(printf '%s' "${full_facts[1]}" | jq -r '.facts.owner.attrSite')"
assert_eq "p01.4 the two schemas agree on every fact VALUE" \
  "true" \
  "$(jq -n --argjson a "${full_facts[0]}" --argjson b "${full_facts[1]}" \
      '($a.facts|with_entries(.value|=.value)) == ($b.facts|with_entries(.value|=.value))')"
assert_eq "p01.5 rev is read, not reconstructed" \
  "4df971884fa974c49b944ba648f2e48a82404c84 DERIVATION_ATTR" \
  "$(printf '%s' "${full_facts[0]}" | jq -r '[.facts.rev.value,.facts.rev.source]|join(" ")')"

# ---------------------------------------------------------------------------
head_ "p02  an absent attribute is UNKNOWN -- never a guess"
mapfile -t bare_facts < <(both_schemas_facts "$ATTRS_BARE")
for i in 0 1; do
  s=$([ "$i" = 0 ] && echo envelope || echo flat-map)
  assert_eq "p02.$((i+1)) $s: absent owner is UNKNOWN with a null value" \
    "null UNKNOWN" \
    "$(printf '%s' "${bare_facts[$i]}" | jq -r '[(.facts.owner.value|tostring),.facts.owner.source]|join(" ")')"
done
# THE RED CONTROL for p02. An UNKNOWN that is UNKNOWN whatever the document
# says is not a reading, it is a constant -- and a constant that happens to be
# the cautious value is the hardest kind to notice.
assert_eq "p02.3 red control: the same reader says DERIVATION_ATTR when the attribute IS there" \
  "DERIVATION_ATTR" \
  "$(printf '%s' "${full_facts[0]}" | jq -r '.facts.owner.source')"
assert_ne "p02.4 and the two readings are not the same object" \
  "$(printf '%s' "${full_facts[0]}" | jq -c '.facts')" \
  "$(printf '%s' "${bare_facts[0]}" | jq -c '.facts')"

# ---------------------------------------------------------------------------
head_ "p03  stripRoot = false is a STATED false, not an absence"
# DESIGN.md §307 names this field as the one that punishes `// null`, because a
# stated false and a missing key render identically through it -- and the fact
# whose entire job is recording that the root was NOT stripped then reports
# UNKNOWN. Read through has(), it is a fact with a value of false.
ATTRS_FALSE='{"urls":["https://example.org/x.tar.gz"],"stripRoot":false}'
mapfile -t false_facts < <(both_schemas_facts "$ATTRS_FALSE")
for i in 0 1; do
  s=$([ "$i" = 0 ] && echo envelope || echo flat-map)
  assert_eq "p03.$((i+1)) $s: stripRoot=false reads as DERIVATION_ATTR / false" \
    "false DERIVATION_ATTR" \
    "$(printf '%s' "${false_facts[$i]}" | jq -r '[(.facts.stripRoot.value|tostring),.facts.stripRoot.source]|join(" ")')"
done
assert_eq "p03.3 red control: stripRoot absent really is UNKNOWN" \
  "UNKNOWN" \
  "$(printf '%s' "${bare_facts[0]}" | jq -r '.facts.stripRoot.source')"

# ---------------------------------------------------------------------------
head_ "p04  rev is NEVER synthesised from a URL"
# The bare document's URL literally contains the revision. PREREG.md §4.1
# permits no URL fallback for rev, and this is the test that would catch one
# being added later for convenience.
assert_eq "p04.1 the URL contains a revision-looking string" \
  "1" "$(printf '%s' "$ATTRS_BARE" | grep -c '4df9718' || true)"
assert_eq "p04.2 and rev is still UNKNOWN" \
  "null UNKNOWN" \
  "$(printf '%s' "${bare_facts[0]}" | jq -r '[(.facts.rev.value|tostring),.facts.rev.source]|join(" ")')"
assert_eq "p04.3 no fact anywhere claims URL_FALLBACK except originHost" \
  "originHost" \
  "$(printf '%s' "${bare_facts[0]}" | jq -r '[.facts|to_entries[]|select(.value.source=="URL_FALLBACK")|.key]|join(",")')"

# ---------------------------------------------------------------------------
head_ "p05  originHost is the one permitted fallback, and it says so"
assert_eq "p05.1 parsed from the URL, marked URL_FALLBACK" \
  "github.com URL_FALLBACK url" \
  "$(printf '%s' "${bare_facts[0]}" | jq -r '[.facts.originHost.value,.facts.originHost.source,.facts.originHost.attrSite]|join(" ")')"
# A direct attribute outranks the fallback, and is labelled differently.
ATTRS_DIRECT_HOST='{"urls":["https://mirror.example.net/x.tar.gz"],"originHost":"github.com"}'
mapfile -t direct_host < <(both_schemas_facts "$ATTRS_DIRECT_HOST")
assert_eq "p05.2 a direct attribute wins and is labelled DERIVATION_ATTR" \
  "github.com DERIVATION_ATTR" \
  "$(printf '%s' "${direct_host[0]}" | jq -r '[.facts.originHost.value,.facts.originHost.source]|join(" ")')"
# TWO hosts is worse than none: there is no single origin host, and taking the
# first is taking whichever the fetcher happened to list first.
ATTRS_TWO_HOSTS='{"urls":["https://a.example.net/x.tar.gz","https://b.example.org/x.tar.gz"]}'
mapfile -t two_hosts < <(both_schemas_facts "$ATTRS_TWO_HOSTS")
assert_eq "p05.3 mirrored URLs on two hosts yield UNKNOWN, with the count kept" \
  "UNKNOWN 2" \
  "$(printf '%s' "${two_hosts[0]}" | jq -r '[.facts.originHost.source,(.facts.originHost.urlHostCount|tostring)]|join(" ")')"
ATTRS_NO_URL='{"postFetch":"unpack"}'
mapfile -t no_url < <(both_schemas_facts "$ATTRS_NO_URL")
assert_eq "p05.4 no URL at all is UNKNOWN with a zero count, not an empty string" \
  "UNKNOWN 0" \
  "$(printf '%s' "${no_url[0]}" | jq -r '[.facts.originHost.source,(.facts.originHost.urlHostCount|tostring)]|join(" ")')"

# ---------------------------------------------------------------------------
head_ "p06  attributes are NAMED, not counted"
# EXPERIMENT-PROTOCOL.md §1: count to detect, name to diagnose. Three runs of
# counting anomalies settled nothing in the closed line; one run that named
# them settled it in the first line.
assert_eq "p06.1 the key set comes back, sorted, from the envelope schema" \
  "extension,githubBase,out,owner,postFetch,repo,rev,stripRoot,urls" \
  "$(printf '%s' "${full_facts[0]}" | jq -r '.attrKeys|join(",")')"
# __json is the ENVELOPE 2.24.9 packs attributes into, not an attribute. Left
# in the key set, one derivation would have different attributes on different
# Nix versions for a purely representational reason.
assert_eq "p06.2 identical from the flat map: __json is carriage, not an attribute" \
  "extension,githubBase,out,owner,postFetch,repo,rev,stripRoot,urls" \
  "$(printf '%s' "${full_facts[1]}" | jq -r '.attrKeys|join(",")')"

# ---------------------------------------------------------------------------
head_ "p07  unreadable is not empty"
# env.__json that is not JSON. The standing rule of this repository: a
# representation we cannot read is not an object with nothing in it.
jq -n '{"/nix/store/abcd0000000000000000000000000000-nix-pills-src.drv":
        {name:"x", outputs:{out:{path:"/nix/store/p-x",hash:"sha256-AAA="}},
         env:{__json:"this is not json {{{", out:"/nix/store/p-x"}}}' > "$TMP/broken-raw.json"
nse_drv_map "$TMP/broken-raw.json" > "$TMP/broken.json"
rc=0; out=$(nse_pg_facts_of "$TMP/broken.json" "$DRV" 2>"$TMP/broken.err") || rc=$?
assert_ne "p07.1 an unparseable env.__json is an error" "0" "$rc"
assert_eq "p07.2 and it produces no facts at all, rather than empty ones" "" "$out"
assert_ne "p07.3 and it says what went wrong" "0" \
  "$(grep -c 'not JSON' "$TMP/broken.err" || true)"
# A derivation the document does not contain.
rc=0; out=$(nse_pg_facts_of "$TMP/map.json" "zzzz-absent.drv" 2>"$TMP/absent.err") || rc=$?
assert_ne "p07.4 a derivation that is not in the document is a read failure" "0" "$rc"
assert_eq "p07.5 with nothing on stdout to be mistaken for a reading" "" "$out"
assert_ne "p07.6 and it says so in those words" "0" \
  "$(grep -c 'read failure' "$TMP/absent.err" || true)"

# ---------------------------------------------------------------------------
head_ "p08  CHECKER_ERROR is its own state, at the exit code"
# PREREG.md §17.1. Run in subshells: these helpers exit, which is the point.
rc=0; ( nse_pg_jq -r '.a' <<< '{"a":"x"}' >/dev/null ) 2>/dev/null || rc=$?
assert_eq "p08.1 a jq that works exits 0" "0" "$rc"
rc=0; ( nse_pg_jq -r '.a |' <<< '{"a":"x"}' >/dev/null ) 2>/dev/null || rc=$?
assert_eq "p08.2 a jq PROGRAM error is CHECKER_ERROR (3), not an empty result" "3" "$rc"
rc=0; out=$( ( nse_pg_jq -r '.a' <<< 'not json at all' ) 2>/dev/null ) || rc=$?
assert_eq "p08.3 a jq INPUT error is CHECKER_ERROR too" "3" "$rc"
assert_eq "p08.4 and yields nothing that could read as a negative answer" "" "$out"
# jq exits 0 and still complains: `error` messages from a stderr-writing filter.
rc=0; ( nse_pg_jq -r '.a // empty' <<< '{"b":1}' >/dev/null ) 2>/dev/null || rc=$?
assert_eq "p08.5 a legitimately empty result is NOT an error" "0" "$rc"
# jq -e: false and a program error must not arrive as the same status.
rc=0; ( nse_pg_jq_test '.a == 1' <<< '{"a":1}' ) 2>/dev/null || rc=$?
assert_eq "p08.6 jq -e true is 0" "0" "$rc"
rc=0; ( nse_pg_jq_test '.a == 2' <<< '{"a":1}' ) 2>/dev/null || rc=$?
assert_eq "p08.7 jq -e false is 1 -- a real answer, kept distinct from 3" "1" "$rc"
rc=0; ( nse_pg_jq_test '.a ==' <<< '{"a":1}' ) 2>/dev/null || rc=$?
assert_eq "p08.8 jq -e that cannot compile is 3, not 'false'" "3" "$rc"

# ---------------------------------------------------------------------------
head_ "p09  canonical hashing hashes content, not formatting"
h1=$(printf '{"b":1,"a":2}' | nse_pg_sha256_canonical)
h2=$(printf '{ "a" : 2 ,\n  "b" : 1 }\n' | nse_pg_sha256_canonical)
assert_eq "p09.1 key order and whitespace do not move the digest" "$h1" "$h2"
h3=$(printf '{"a":2,"b":2}' | nse_pg_sha256_canonical)
assert_ne "p09.2 red control: a changed VALUE does move it" "$h1" "$h3"
assert_eq "p09.3 the digest is a sha256, not a truncation of one" \
  "64" "$(printf '%s' "$h1" | wc -c)"

# ---------------------------------------------------------------------------
head_ "p10  the new executable is actually linted, and the lint mirror cannot drift"
# u26 in the CLOSED line's suite mirrors the flake's shellcheck invocation, and
# that file is not this line's to edit. So the drift guard lives here: a second
# executable added to bin/ is exactly the kind of file that gets left out of a
# hand-maintained lint list and stays unlinted for months.
flake=$ROOT/flake.nix
sc_line=$(grep -n 'shellcheck -x -e SC1091' "$flake" | head -1)
assert_ne "p10.1 the flake has a shellcheck invocation" "" "$sc_line"
assert_ne "p10.2 and it lints bin/nse-pg, not just the closed line's executable" "0" \
  "$(printf '%s' "$sc_line" | grep -c 'bin/nse-pg' || true)"
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "  skipped (shellcheck not on PATH)"
else
  # The flake's EXACT flags. A local run without them was reported inconclusive
  # once in the closed line while CI went red on two INFO-level findings.
  sc_out=$(cd "$ROOT" && shellcheck -x -e SC1091 --shell=bash \
             bin/nse-pg lib/pg-*.sh tests/pg-unit.sh 2>&1) && sc_rc=0 || sc_rc=$?
  assert_eq "p10.3 shellcheck is clean on this line's files" "0" "$sc_rc"
  [ "$sc_rc" -eq 0 ] || printf '%s\n' "$sc_out" | head -30
  # Positive control: without one, p10.3 is green whenever shellcheck does
  # nothing at all -- a green lamp wired to the battery.
  sc_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nse-pg-p10.XXXXXX")
  sc_q="'"
  { printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "printf %s ${sc_q}a literal \$HOME here${sc_q}"
  } > "$sc_tmp/bad.sh"
  shellcheck -x -e SC1091 --shell=bash "$sc_tmp/bad.sh" >/dev/null 2>&1 \
    && ctl_rc=0 || ctl_rc=$?
  assert_ne "p10.4 positive control: a known finding does go red" "0" "$ctl_rc"
  rm -rf "$sc_tmp"
fi

printf '\n\033[1mRESULT\033[0m  passed=%d failed=%d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf 'failed tests:\n'; printf '  - %s\n' "${failed_names[@]}"
  exit 1
fi
