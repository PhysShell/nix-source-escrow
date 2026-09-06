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
# shellcheck source=../lib/pg-digest.sh
. "$ROOT/lib/pg-digest.sh"
# shellcheck source=../lib/pg-policy.sh
. "$ROOT/lib/pg-policy.sh"
# shellcheck source=../lib/pg-cache.sh
. "$ROOT/lib/pg-cache.sh"
# shellcheck source=../lib/pg-corpus.sh
. "$ROOT/lib/pg-corpus.sh"
# shellcheck source=../lib/pg-gate.sh
. "$ROOT/lib/pg-gate.sh"
# shellcheck source=../lib/pg-ingest.sh
. "$ROOT/lib/pg-ingest.sh"
# shellcheck source=../lib/pg-scratch.sh
. "$ROOT/lib/pg-scratch.sh"
# shellcheck source=../lib/pg-summary.sh
. "$ROOT/lib/pg-summary.sh"

pass=0; fail=0; failed_names=()
# jq, with its stderr treated as a result -- the same rule lib/pg-common.sh
# applies to the tool, applied to the tests.
#
# p42.12 was written as `jq ... || true` around a filter that errored on a
# `.note` which is sometimes an array. jq printed a diagnostic, produced
# nothing, and the assertion compared "" with "" and PASSED. A checker that
# cannot run is not a checker that found nothing -- PREREG.md §17.1 -- and a
# test suite that exempts itself from its own rule is a test suite with a
# hole in it.
JQ_ERR=""
jqx() {
  local e out rc=0
  e=$(mktemp "$TMP/jqx.XXXXXX")
  out=$(jq "$@" 2>"$e") || rc=$?
  JQ_ERR=$(tr '\n' ' ' < "$e"); rm -f "$e"
  if [ "$rc" -ne 0 ] || [ -n "$JQ_ERR" ]; then
    printf 'CHECKER_ERROR(rc=%s): %s' "$rc" "${JQ_ERR:-no message}"
    return 0
  fi
  printf '%s' "$out"
}
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
# TYPED DIGESTS. PREREG.md §12.
#
# The table below is the pre-registration, executed. Every digest has BOTH a
# mutation that must move it AND a mutation that must not, because a digest
# with only the first is a digest that might be hashing the whole document,
# and a digest with only the second might be a constant.
# ---------------------------------------------------------------------------
SEED=$ROOT/tests/pg-fixtures/facts-seed.json

# mutate <jq-program>  ->  path to a mutated copy of the seed
mut() { local f; f=$(mktemp "$TMP/facts.XXXXXX.json"); jq "$1" "$SEED" > "$f"; printf '%s\n' "$f"; }
dig() { nse_pg_digest_of "$1" "$2"; }
DEP=nse_pg_dep_content_projection
FACTS=nse_pg_policy_facts_projection
SRC=nse_pg_flake_source_projection
DEC=nse_pg_decision_projection

base_dep=$(dig "$SEED" "$DEP")
base_facts=$(dig "$SEED" "$FACTS")
base_src=$(dig "$SEED" "$SRC")

head_ "p11  the seed is the shape a recorded document has, not a convenient one"
# EXPERIMENT-PROTOCOL.md §1, the "fixture the world never produces" shape. A
# synthetic seed is permitted (PREREG.md §11.1) and is a MECHANISM test only --
# but it still has to validate against the schema of a real document, or the
# mechanism is tested against a document that will never arrive.
assert_eq "p11.1 the seed declares itself synthetic, in the file" \
  "SYNTHETIC" "$(jq -r .seedProvenance "$SEED")"
assert_eq "p11.2 every dependency carries a class the digest understands" "" \
  "$(jq -r '[.dependencies[] | select((.class == "fod" or .class == "flake-input") | not)] | .[].id // empty' "$SEED")"
assert_eq "p11.3 every fod carries the four content-identity fields" "" \
  "$(jq -r '[.dependencies[] | select(.class=="fod")
             | select((.contentIdentity | has("storePath") and has("expectedHash")
                       and has("expectedHashAlgo") and has("hashMode")) | not)] | .[].id // empty' "$SEED")"
assert_eq "p11.4 every flake input carries storePath and narHash" "" \
  "$(jq -r '[.dependencies[] | select(.class=="flake-input")
             | select((.contentIdentity | has("storePath") and has("narHash")) | not)] | .[].id // empty' "$SEED")"
assert_eq "p11.5 the seed exercises BOTH classes and both requiredByPlan values" \
  "fod,flake-input true,false" \
  "$(jq -r '[([.dependencies[].class]|unique|sort_by(.=="fod")|reverse|join(",")),
             ([.dependencies[].requiredByPlan]|unique|sort|reverse|map(tostring)|join(","))] | join(" ")' "$SEED")"
# An unknown class must be a READ FAILURE, not a silently skipped dependency.
weird=$(mut '.dependencies[0].class = "something-new"')
rc=0; dig "$weird" "$DEP" >/dev/null 2>&1 || rc=$?
assert_ne "p11.6 an unrecognised dependency class is an error, not a skipped entry" "0" "$rc"

head_ "p12  dependencyContentDigest moves on bytes, and ONLY on bytes"
assert_ne "p12.1 MOVES: a changed expectedHash" \
  "$base_dep" "$(dig "$(mut '.dependencies[0].contentIdentity.expectedHash = "sha256-ZZZZ="')" "$DEP")"
assert_ne "p12.2 MOVES: a changed storePath" \
  "$base_dep" "$(dig "$(mut '.dependencies[0].contentIdentity.storePath = "/nix/store/zzzz-other"')" "$DEP")"
assert_ne "p12.3 MOVES: a changed hash ALGORITHM at the same digest" \
  "$base_dep" "$(dig "$(mut '.dependencies[0].contentIdentity.expectedHashAlgo = "sha512"')" "$DEP")"
assert_ne "p12.4 MOVES: a required source added" \
  "$base_dep" "$(dig "$(mut '.dependencies += [{id:"fod:/nix/store/new",class:"fod",kind:"fetchurl",requiredByPlan:true,drvPath:null,contentIdentity:{storePath:"/nix/store/new",expectedHash:"sha256-N=",expectedHashAlgo:"sha256",hashMode:"flat"},originHost:{value:"x",source:"URL_FALLBACK"},owner:{value:null,source:"UNKNOWN"},repo:{value:null,source:"UNKNOWN"},rev:{value:null,source:"UNKNOWN"},tag:{value:null,source:"UNKNOWN"},aliasPaths:[],discoveryStatus:"COVERED",annotation:null}]')" "$DEP")"
assert_ne "p12.5 MOVES: a required source removed" \
  "$base_dep" "$(dig "$(mut '.dependencies |= map(select(.class != "flake-input"))')" "$DEP")"
# The four that must NOT move it. Each is a real thing that happens.
assert_eq "p12.6 HOLDS: a changed drvPath -- C4 says an annotation moves this legitimately" \
  "$base_dep" "$(dig "$(mut '.dependencies[0].drvPath = "/nix/store/9999-annotated.drv"')" "$DEP")"
assert_eq "p12.7 HOLDS: a changed originHost -- same bytes, new origin" \
  "$base_dep" "$(dig "$(mut '.dependencies[0].originHost.value = "codeberg.org"')" "$DEP")"
assert_eq "p12.8 HOLDS: a changed lockNodeId -- systems vs systems_2 is a name, not an identity" \
  "$base_dep" "$(dig "$(mut '.dependencies[2].lockNodeId = "gitignore-src_2"')" "$DEP")"
assert_eq "p12.9 HOLDS: the dependency list reordered" \
  "$base_dep" "$(dig "$(mut '.dependencies |= reverse')" "$DEP")"
assert_eq "p12.10 HOLDS: a NON-required source changed -- it is not in the required set" \
  "$base_dep" "$(dig "$(mut '.dependencies[1].contentIdentity.expectedHash = "sha256-CHANGED="')" "$DEP")"
assert_eq "p12.11 HOLDS: the project flake source changed" \
  "$base_dep" "$(dig "$(mut '.flakeSource.narHash = "sha256-README="')" "$DEP")"

head_ "p13  policyFactsDigest moves on what a SELECTOR can read"
assert_ne "p13.1 MOVES: a changed originHost" \
  "$base_facts" "$(dig "$(mut '.dependencies[0].originHost.value = "codeberg.org"')" "$FACTS")"
assert_ne "p13.2 MOVES: a changed owner" \
  "$base_facts" "$(dig "$(mut '.dependencies[0].owner.value = "SomeoneElse"')" "$FACTS")"
assert_ne "p13.3 MOVES: a changed discoveryStatus" \
  "$base_facts" "$(dig "$(mut '.dependencies[0].discoveryStatus = "EXTERNAL_RECOVERY"')" "$FACTS")"
assert_ne "p13.4 MOVES: a changed aliasPath" \
  "$base_facts" "$(dig "$(mut '.dependencies[2].aliasPaths = ["renamed"]')" "$FACTS")"
# PROVENANCE is part of the fact. A value that stops being stated and starts
# being inferred is a different fact for policy purposes -- §7.3 makes rules
# behave differently on an UNKNOWN, so a silent transition here would let a
# selector change behaviour with no digest moving.
assert_ne "p13.5 MOVES: the same owner VALUE, arriving with different provenance" \
  "$base_facts" "$(dig "$(mut '.dependencies[0].owner.source = "URL_FALLBACK"')" "$FACTS")"
assert_eq "p13.6 HOLDS: a changed drvPath" \
  "$base_facts" "$(dig "$(mut '.dependencies[0].drvPath = "/nix/store/9999-annotated.drv"')" "$FACTS")"
assert_eq "p13.7 HOLDS: the dependency list reordered" \
  "$base_facts" "$(dig "$(mut '.dependencies |= reverse')" "$FACTS")"
assert_eq "p13.8 HOLDS: the project flake source changed" \
  "$base_facts" "$(dig "$(mut '.flakeSource.narHash = "sha256-README="')" "$FACTS")"

head_ "p14  the C3 observable, as one assertion"
# PREREG.md §12: origin moved, content identical. THIS is what makes a
# policy-relevant change impossible to hide behind an unchanged content hash,
# and it is one mutation producing two different answers.
moved=$(mut '.dependencies[0].originHost.value = "evil.example.com"')
assert_eq "p14.1 dependencyContentDigest is UNCHANGED" "$base_dep" "$(dig "$moved" "$DEP")"
assert_ne "p14.2 policyFactsDigest is CHANGED" "$base_facts" "$(dig "$moved" "$FACTS")"

head_ "p15  the README-only observable"
# 166 external dependencies did not change because somebody edited a README.
readme=$(mut '.flakeSource.narHash = "sha256-JustTheReadme="')
assert_eq "p15.1 dependencyContentDigest UNCHANGED" "$base_dep" "$(dig "$readme" "$DEP")"
assert_eq "p15.2 policyFactsDigest UNCHANGED" "$base_facts" "$(dig "$readme" "$FACTS")"
assert_ne "p15.3 flakeSourceDigest CHANGED" "$base_src" "$(dig "$readme" "$SRC")"
assert_eq "p15.4 HOLDS: flakeSourceDigest ignores every dependency-only change" \
  "$base_src" "$(dig "$(mut '.dependencies[0].contentIdentity.expectedHash = "sha256-ZZZ="')" "$SRC")"

head_ "p16  effectiveDecisionDigest"
withdec=$(mut '. + {decisions: [
  {sourceId:"a", matchedRuleIds:["r1","r2"], effective:{coverage:"required",retention:"permanent",admission:"normal"}, trustedPolicyRevision:"base-sha-1"},
  {sourceId:"b", matchedRuleIds:["r1"], effective:{coverage:"auto",retention:"while-referenced",admission:"normal"}, trustedPolicyRevision:"base-sha-1"}]}')
base_dec=$(dig "$withdec" "$DEC")
assert_ne "p16.1 MOVES: a changed effective axis" "$base_dec" \
  "$(dig "$(jq '.decisions[1].effective.coverage = "required"' "$withdec" > "$TMP/d1.json"; echo "$TMP/d1.json")" "$DEC")"
assert_ne "p16.2 MOVES: a changed matched-rule set" "$base_dec" \
  "$(dig "$(jq '.decisions[0].matchedRuleIds = ["r1","r3"]' "$withdec" > "$TMP/d2.json"; echo "$TMP/d2.json")" "$DEC")"
assert_ne "p16.3 MOVES: a changed trusted policy revision, same verdicts" "$base_dec" \
  "$(dig "$(jq '.decisions[].trustedPolicyRevision = "base-sha-2"' "$withdec" > "$TMP/d3.json"; echo "$TMP/d3.json")" "$DEC")"
assert_eq "p16.4 HOLDS: the decision list reordered" "$base_dec" \
  "$(dig "$(jq '.decisions |= reverse' "$withdec" > "$TMP/d4.json"; echo "$TMP/d4.json")" "$DEC")"
assert_eq "p16.5 HOLDS: the matched-rule ids reordered within a decision" "$base_dec" \
  "$(dig "$(jq '.decisions[0].matchedRuleIds = ["r2","r1"]' "$withdec" > "$TMP/d5.json"; echo "$TMP/d5.json")" "$DEC")"
# ABSENT is null, not the sha256 of an empty array -- which is a real-looking
# digest that any two decisionless documents would agree on.
assert_eq "p16.6 a facts document with no decisions reports null, not a digest of nothing" \
  "null" "$(nse_pg_digests "$SEED" | jq -r '.effectiveDecisionDigest | tostring')"
assert_ne "p16.7 and one WITH decisions reports a digest" \
  "null" "$(nse_pg_digests "$withdec" | jq -r '.effectiveDecisionDigest | tostring')"

head_ "p17  the comparison names the SHAPE, never just 'changed'"
b=$TMP/dig-base.json; h=$TMP/dig-head.json
nse_pg_digests "$SEED" > "$b"
nse_pg_digests "$moved" > "$h"
assert_eq "p17.1 origin moved is named" "ORIGIN_MOVED_OR_FACTS_CHANGED" \
  "$(nse_pg_digest_compare "$b" "$h" | jq -r .shape)"
nse_pg_digests "$readme" > "$h"
assert_eq "p17.2 a README-only change is named, and is not 166 dependencies" \
  "PROJECT_SOURCE_ONLY" "$(nse_pg_digest_compare "$b" "$h" | jq -r .shape)"
nse_pg_digests "$(mut '.dependencies[0].contentIdentity.expectedHash = "sha256-REAL="')" > "$h"
assert_eq "p17.3 changed bytes are named" "DEPENDENCY_BYTES_CHANGED" \
  "$(nse_pg_digest_compare "$b" "$h" | jq -r .shape)"
nse_pg_digests "$(mut '.dependencies[0].drvPath = "/nix/store/annotated.drv"')" > "$h"
assert_eq "p17.4 an annotation alone is NO_RELEVANT_CHANGE, not a supply-chain event" \
  "NO_RELEVANT_CHANGE" "$(nse_pg_digest_compare "$b" "$h" | jq -r .shape)"

head_ "p18  the digests are not each other, and not a hash of the whole document"
# The failure this design exists to prevent: four names for one number.
assert_ne "p18.1 dependencyContent != policyFacts" "$base_dep" "$base_facts"
assert_ne "p18.2 dependencyContent != flakeSource" "$base_dep" "$base_src"
assert_ne "p18.3 policyFacts != flakeSource" "$base_facts" "$base_src"
whole=$(sha256sum "$SEED" | cut -d' ' -f1)
assert_ne "p18.4 and none of them is just sha256(the document)" "$whole" "$base_dep"
# The projection is printable. A digest whose input cannot be shown is a number
# that can only be trusted, and "about what?" has to be answerable.
assert_eq "p18.5 the projection can be printed, and covers only the required set" \
  "2" "$(nse_pg_project "$SEED" "$DEP" | jq 'length')"
assert_eq "p18.6 while the policy-facts projection covers every discovered dependency" \
  "3" "$(nse_pg_project "$SEED" "$FACTS" | jq 'length')"

# ---------------------------------------------------------------------------
# POLICY AND MATCHER. PREREG.md §6, §7, §13.
# ---------------------------------------------------------------------------
# The refusal text goes to a KNOWN file, because a test that asserts on a
# message has to be able to read the message. The first version sent it to
# $f.err and then grepped a different file -- the assertion was about an empty
# file, which is the "asserts a constant" shape from EXPERIMENT-PROTOCOL.md §1.
POLICY_ERR=$TMP/policy-load.err
# The revision is a REQUIRED argument, passed at every call site.
#
# It was optional, with a default, and never passed -- which SC2120 reported on
# the runner while the locally installed shellcheck 0.11.0 said nothing.
# (Note the wording: a comment line that BEGINS with the word shellcheck is
# parsed as a directive, and the first draft of this very comment was a
# SC1072/SC1073 parse error.)
# Making it required is better than silencing the finding: the trusted
# policy revision is the thing every decision carries as provenance, and a test
# that never states which revision it is testing under is a test that has
# stopped caring about the field.
policy_of() {  # $1 = revision; TOML text on stdin -> path to loaded policy JSON
  local rev=$1
  local f; f=$(mktemp "$TMP/pol.XXXXXX.toml"); cat > "$f"
  local j; j=$(mktemp "$TMP/pol.XXXXXX.json")
  # A subshell: nse_pg_policy_load EXITS on a checker error, and an exit inside
  # this suite would end the suite rather than the assertion -- the
  # "destroys its own specimen" shape.
  if ( nse_pg_policy_load "$f" "$rev" ) > "$j" 2>"$POLICY_ERR"; then
    printf '%s\n' "$j"
  else
    return 1
  fi
}
decide_with() {  # $1 = policy json, $2 = facts json -> decisions json path
  local d; d=$(mktemp "$TMP/dec.XXXXXX.json")
  nse_pg_decide "$2" "$1" > "$d" || return 1
  printf '%s\n' "$d"
}

head_ "p19  the policy reader refuses what it does not understand"
# THE security property of this reader, and not a limitation to apologise for.
# A reader that ignores an unrecognised key reads a rule with a MISTYPED
# SELECTOR as a rule with NO selectors: specificity 0, matching every
# dependency, exempting all of them. A typo becomes a blanket exemption.
rc=0; printf '%s\n' '[[rule]]' 'id = "r1"' 'ownr = "NixOS"' 'coverage = "ignore"' \
        | policy_of rev-test >/dev/null 2>/dev/null || rc=$?
assert_ne "p19.1 a MISTYPED SELECTOR is refused, not ignored" "0" "$rc"
assert_ne "p19.2 and the refusal names the key, so the author can find it" "0" \
  "$(grep -c 'ownr' "$POLICY_ERR" || true)"
assert_ne "p19.2a and lists what WAS permitted" "0" \
  "$(grep -c 'Permitted: id, contentIdentity' "$POLICY_ERR" || true)"
# The red control for p19.1: the CORRECT spelling must load.
rc=0; printf '%s\n' '[[rule]]' 'id = "r1"' 'owner = "NixOS"' 'coverage = "ignore"' \
        | policy_of rev-test >/dev/null 2>/dev/null || rc=$?
assert_eq "p19.3 red control: the correctly spelled selector DOES load" "0" "$rc"
rc=0; printf '%s\n' '[[rule]]' 'coverage = "required"' | policy_of rev-test >/dev/null 2>/dev/null || rc=$?
assert_ne "p19.4 a rule with no id is refused -- an id is the provenance a decision carries" "0" "$rc"
rc=0; printf '%s\n' '[[rule]]' 'id = "dup"' 'owner = "a"' '[[rule]]' 'id = "dup"' 'owner = "b"' \
        | policy_of rev-test >/dev/null 2>/dev/null || rc=$?
assert_ne "p19.5 duplicate ids are refused -- two rules with one id make provenance a lie" "0" "$rc"
rc=0; printf '%s\n' '[nonsense]' 'x = "y"' | policy_of rev-test >/dev/null 2>/dev/null || rc=$?
assert_ne "p19.6 an unknown table is refused" "0" "$rc"
rc=0; printf '%s\n' 'this is not toml at all' | policy_of rev-test >/dev/null 2>/dev/null || rc=$?
assert_ne "p19.7 an unparseable line is refused" "0" "$rc"
rc=0; printf '' | policy_of rev-test >/dev/null 2>/dev/null || rc=$?
assert_ne "p19.8 an EMPTY policy is a read failure, not a policy that governs nothing" "0" "$rc"
rc=0; printf '%s\n' '[defaults]' 'coverge = "auto"' | policy_of rev-test >/dev/null 2>/dev/null || rc=$?
assert_ne "p19.9 a mistyped key in [defaults] is refused too" "0" "$rc"

head_ "p20  precedence is specificity, never the order of the file"
POL_A=$(printf '%s\n' \
  '[[rule]]' 'id = "r-host"'  'originHost = "github.com"' 'coverage = "ignore"' \
  '[[rule]]' 'id = "r-owner"' 'originHost = "github.com"' 'owner = "NixOS"' 'coverage = "required"' \
  | policy_of rev-test)
D=$(decide_with "$POL_A" "$SEED")
assert_eq "p20.1 the more specific rule wins the axis (6 vs 6+8)" \
  "required r-owner" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | [.effective.coverage, .axisWonBy.coverage] | join(" ")' "$D")"
# THE SAME TWO RULES, FILE ORDER REVERSED. If this moves, precedence is order.
POL_B=$(printf '%s\n' \
  '[[rule]]' 'id = "r-owner"' 'originHost = "github.com"' 'owner = "NixOS"' 'coverage = "required"' \
  '[[rule]]' 'id = "r-host"'  'originHost = "github.com"' 'coverage = "ignore"' \
  | policy_of rev-test)
D2=$(decide_with "$POL_B" "$SEED")
assert_eq "p20.2 reversing the FILE does not move a single verdict" \
  "$(jq -Sc '[.decisions[] | {sourceId, effective, matchedRuleIds, axisWonBy}]' "$D")" \
  "$(jq -Sc '[.decisions[] | {sourceId, effective, matchedRuleIds, axisWonBy}]' "$D2")"
assert_eq "p20.3 declared order is recorded, so it was AVAILABLE to be used and was not" \
  "0,1" "$(jq -r '[.rules[].declaredOrder] | join(",")' "$POL_A")"
# A rule with no selectors is the declared default, and loses to anything.
POL_C=$(printf '%s\n' \
  '[[rule]]' 'id = "r-catchall"' 'coverage = "required"' \
  '[[rule]]' 'id = "r-kind"' 'kind = "fetchurl"' 'coverage = "ignore"' \
  | policy_of rev-test)
D3=$(decide_with "$POL_C" "$SEED")
assert_eq "p20.4 a selectorless rule matches everything, at specificity 0" \
  "required" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .effective.coverage' "$D3")"
assert_eq "p20.5 and any real selector outranks it" \
  "ignore r-kind" \
  "$(jq -r '.decisions[] | select(.sourceId | test("hello")) | [.effective.coverage, .axisWonBy.coverage] | join(" ")' "$D3")"

head_ "p21  a tie that disagrees FAILS CLOSED"
# Not "last wins", which makes the verdict a function of file order. Not "most
# restrictive wins", which is a silent join hiding a policy nobody wrote.
POL_T=$(printf '%s\n' \
  '[[rule]]' 'id = "r-a"' 'owner = "NixOS"' 'coverage = "required"' \
  '[[rule]]' 'id = "r-b"' 'owner = "NixOS"' 'coverage = "ignore"' \
  | policy_of rev-test)
DT=$(decide_with "$POL_T" "$SEED")
assert_eq "p21.1 the conflict is recorded as RULE_CONFLICT" "RULE_CONFLICT" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .conflicts[0].kind' "$DT")"
assert_eq "p21.2 and the axis has NO value -- not the safe one, none" "null" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .effective.coverage | tostring' "$DT")"
assert_eq "p21.3 and mustPreserve is UNDECIDED rather than a guess" "null UNDECIDED" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | [(.mustPreserve|tostring), .acceptance] | join(" ")' "$DT")"
assert_eq "p21.4 the conflict names both rules and the tied specificity" "1" \
  "$(jq -r '[.decisions[] | .conflicts[] | select(.kind=="RULE_CONFLICT")
            | select((.detail | test("r-a")) and (.detail | test("r-b")) and (.detail | test("specificity")))] | length' "$DT")"
# Red control: a tie assigning the SAME value is not a conflict.
POL_S=$(printf '%s\n' \
  '[[rule]]' 'id = "r-a"' 'owner = "NixOS"' 'coverage = "required"' \
  '[[rule]]' 'id = "r-b"' 'owner = "NixOS"' 'coverage = "required"' \
  | policy_of rev-test)
DS=$(decide_with "$POL_S" "$SEED")
assert_eq "p21.5 red control: a tie AGREEING is not a conflict" "0" \
  "$(jq -r '.counts.ruleConflicts' "$DS")"
assert_eq "p21.6 and it resolves normally" "required" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .effective.coverage' "$DS")"

head_ "p22  annotations may only strengthen -- C1 at the axis level"
POL_REQ=$(printf '%s\n' '[[rule]]' 'id = "r-req"' 'owner = "NixOS"' 'coverage = "required"' | policy_of rev-test)
# base auto + annotation required -> required
F_UP=$(mut '.dependencies[1].annotation = {coverage: "required"}')
D_UP=$(decide_with "$POL_REQ" "$F_UP")
assert_eq "p22.1 base auto + annotation required -> required" "required" \
  "$(jq -r '.decisions[] | select(.sourceId | test("hello")) | .effective.coverage' "$D_UP")"
assert_eq "p22.2 and that is not a conflict" "0" "$(jq -r '.counts.policyConflicts' "$D_UP")"
# base required + annotation ignore -> required, POLICY_CONFLICT recorded
F_DOWN=$(mut '.dependencies[0].annotation = {coverage: "ignore"}')
D_DOWN=$(decide_with "$POL_REQ" "$F_DOWN")
assert_eq "p22.3 base required + annotation ignore -> REQUIRED, the base stands" "required" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .effective.coverage' "$D_DOWN")"
assert_eq "p22.4 and a POLICY_CONFLICT is recorded, not swallowed" "POLICY_CONFLICT" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .conflicts[0].kind' "$D_DOWN")"
assert_eq "p22.5 mustPreserve is still true -- the annotation bought nothing" "true" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .mustPreserve | tostring' "$D_DOWN")"
# All three axes, not just coverage.
F_ALL=$(mut '.dependencies[0].annotation = {coverage: "ignore", retention: "while-referenced", admission: "normal"}')
POL_STRONG=$(printf '%s\n' '[[rule]]' 'id = "r-s"' 'owner = "NixOS"' \
  'coverage = "required"' 'retention = "permanent"' 'admission = "quarantine"' | policy_of rev-test)
D_ALL=$(decide_with "$POL_STRONG" "$F_ALL")
assert_eq "p22.6 no axis can be walked down by an annotation" \
  "required permanent quarantine" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | [.effective.coverage,.effective.retention,.effective.admission] | join(" ")' "$D_ALL")"
assert_eq "p22.7 and all three refusals are recorded" "3" \
  "$(jq -r '[.decisions[] | .conflicts[] | select(.kind=="POLICY_CONFLICT")] | length' "$D_ALL")"
# A real exemption is grantable by the BASE policy and by nothing else.
POL_IGN=$(printf '%s\n' '[[rule]]' 'id = "r-ign"' 'owner = "NixOS"' 'coverage = "ignore"' | policy_of rev-test)
D_IGN=$(decide_with "$POL_IGN" "$SEED")
assert_eq "p22.8 the BASE policy CAN grant a real ignore" "ignore false" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | [.effective.coverage, (.mustPreserve|tostring)] | join(" ")' "$D_IGN")"
# An off-axis value is a load error, not the bottom of the order.
F_BAD=$(mut '.dependencies[0].annotation = {coverage: "requred"}')
# A SUBSHELL. nse_pg_decide exits on a checker error, and an unguarded exit
# here ends the suite mid-way rather than the assertion -- which is exactly
# how a `find | head` under pipefail once killed a whole run in the closed
# line, and the tests after it were never reported at all.
rc=0; ( nse_pg_decide "$F_BAD" "$POL_REQ" ) >/dev/null 2>&1 || rc=$?
assert_ne "p22.9 a MISSPELLED annotation value is an error, not the weakest value" "0" "$rc"

head_ "p23  an UNKNOWN fact does not match, and says why"
# PREREG.md §7.3. Not permissively, not conservatively -- it does not match,
# and the reason is recorded so an inert rule is diagnosable.
POL_OWNER=$(printf '%s\n' '[[rule]]' 'id = "r-owner"' 'owner = "NixOS"' 'coverage = "required"' | policy_of rev-test)
D_UNK=$(decide_with "$POL_OWNER" "$SEED")
assert_eq "p23.1 the hello tarball has owner UNKNOWN and does NOT match" "" \
  "$(jq -r '.decisions[] | select(.sourceId | test("hello")) | .matchedRuleIds | join(",")' "$D_UNK")"
assert_eq "p23.2 and the non-match is attributed to the unknown fact, by name" \
  "r-owner owner" \
  "$(jq -r '.decisions[] | select(.sourceId | test("hello")) | .unmatchedForUnknownFact[0] | [.ruleId, (.selectors|join(","))] | join(" ")' "$D_UNK")"
assert_eq "p23.3 it falls through to the declared default rather than to a guess" \
  "auto DEFAULT" \
  "$(jq -r '.decisions[] | select(.sourceId | test("hello")) | [.effective.coverage, .axisSource.coverage] | join(" ")' "$D_UNK")"
# Red control: a KNOWN fact with the same value does match.
assert_eq "p23.4 red control: the dependency whose owner IS known matches it" "r-owner" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .matchedRuleIds | join(",")' "$D_UNK")"
# A fact present but UNKNOWN-sourced must behave exactly like an absent one.
F_SRC=$(mut '.dependencies[0].owner = {value: "NixOS", source: "UNKNOWN", attrKey: null, attrSite: null}')
D_SRC=$(decide_with "$POL_OWNER" "$F_SRC")
assert_eq "p23.5 a fact whose PROVENANCE is UNKNOWN does not match, whatever value it carries" "" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .matchedRuleIds | join(",")' "$D_SRC")"

head_ "p24  every decision carries its provenance"
DP=$(decide_with "$POL_REQ" "$SEED")
assert_eq "p24.1 every decision names the trusted policy revision" "3" \
  "$(jq -r '[.decisions[] | select(.trustedPolicyRevision == "rev-test")] | length' "$DP")"
assert_eq "p24.2 and which rule won each axis it did not default" "r-req" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .axisWonBy.coverage' "$DP")"
assert_eq "p24.3 a defaulted axis says DEFAULT rather than naming a rule" "DEFAULT null" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | [.axisSource.retention, (.axisWonBy.retention|tostring)] | join(" ")' "$DP")"
assert_eq "p24.4 the decision digest is computable from the decisions document" "64" \
  "$(printf '%s' "$(nse_pg_digest_of "$DP" nse_pg_decision_projection)" | wc -c | tr -d ' ')"

head_ "p25  coverage semantics: auto means what the plan used"
POL_AUTO=$(printf '%s\n' '[defaults]' 'coverage = "auto"' | policy_of rev-test)
DA=$(decide_with "$POL_AUTO" "$SEED")
assert_eq "p25.1 auto + requiredByPlan  -> preserve" "true" \
  "$(jq -r '.decisions[] | select(.sourceId | test("nix-pills")) | .mustPreserve | tostring' "$DA")"
assert_eq "p25.2 auto + NOT requiredByPlan -> do not" "false" \
  "$(jq -r '.decisions[] | select(.sourceId | test("hello")) | .mustPreserve | tostring' "$DA")"
POL_RQ=$(printf '%s\n' '[defaults]' 'coverage = "required"' | policy_of rev-test)
DR=$(decide_with "$POL_RQ" "$SEED")
assert_eq "p25.3 required preserves even what the plan never reached" "true" \
  "$(jq -r '.decisions[] | select(.sourceId | test("hello")) | .mustPreserve | tostring' "$DR")"

# ---------------------------------------------------------------------------
# THE ADVERSARIAL CORPUS. PREREG.md §11.
#
# Five proposals, each with a base state and a head state. Not unit tests of a
# function -- proposals, gated the way a real one would be.
#
# EVERY fixture is gated base-against-base FIRST. That control is not
# ceremony: without it, a corpus whose baseline happens to be red proves
# nothing at all, because every specimen would be rejected with the guard under
# test deleted. The first version of this corpus had exactly that defect --
# all five were REJECTED, and three of them for a reason that had nothing to do
# with what they were built to demonstrate.
# ---------------------------------------------------------------------------
CORPUS=$ROOT/experiments/policy-governed/fixtures
gate_run() {  # $1 fixture, $2 candidate side (base|head) -> report path
  local out; out=$TMP/gate-$1-$2.json
  ( nse_pg_gate "$CORPUS/$1/base" "$CORPUS/$1/$2" "$out" "base-$1" "$2-$1" ) >/dev/null 2>&1 || true
  printf '%s\n' "$out"
}

head_ "p25b  the corpus is a FUNCTION of a seed, and the checked-in copy has not drifted"
# PREREG.md §11.1 turns on the seed: a SYNTHETIC one makes the corpus a
# mechanism test, a RECORDED one makes it evidence. That only works if the same
# code produces both -- so the fixtures in git are the generator's output, and
# this asserts it byte for byte. A hand-edited fixture is a fixture whose
# recorded twin proves something else.
REGEN=$TMP/corpus-regen
nse_pg_corpus_generate "$ROOT/tests/pg-fixtures/facts-seed.json" "$REGEN" >/dev/null 2>&1
drift=$(diff -r --exclude=qualification "$CORPUS" "$REGEN" 2>&1 | head -20 || true)
assert_eq "p25b.1 the checked-in corpus is exactly what the generator emits" "" "$drift"
assert_eq "p25b.2 and it declares its seed provenance in the tree" "SYNTHETIC" \
  "$(jq -r .seedProvenance "$CORPUS/SEED.json")"
assert_ne "p25b.3 and says, in the file, what that provenance MEANS" "0" \
  "$(jq -r '.meaning | test("MECHANISM TEST") | if . then 1 else 0 end' "$CORPUS/SEED.json")"
assert_ne "p25b.4 and that the added adversarial dependency is constructed either way" "0" \
  "$(jq -r '.caveat | test("does not make the attack real") | if . then 1 else 0 end' "$CORPUS/SEED.json")"
# A seed that does not declare its provenance cannot be used at all.
jq 'del(.seedProvenance)' "$ROOT/tests/pg-fixtures/facts-seed.json" > "$TMP/noprov.json"
rc=0; ( nse_pg_corpus_generate "$TMP/noprov.json" "$TMP/noprov-corpus" ) >/dev/null 2>&1 || rc=$?
assert_eq "p25b.5 a seed with no declared provenance is refused, not defaulted" "3" "$rc"
# THE POINT OF THE GENERATOR: the same mutations on a RECORDED seed, at real
# scale, with sources whose origin was never observed -- and the controls must
# still be ACCEPTED, or the corpus stops proving anything.
python3 - "$TMP/big-seed.json" <<'PYEOF'
import json, sys, random
random.seed(11)
hosts = ["github.com", "ftp.gnu.org", "cache.nixos.org", "codeberg.org"]
deps = []
for i in range(120):
    sp = "/nix/store/%032d-dep%03d" % (i, i)
    unknown = (i % 50 == 0)
    deps.append({
      "id": "fod:" + sp, "class": "fod",
      "kind": random.choice(["fetchurl", "fetchzip-like", "builtin:fetchurl"]),
      "requiredByPlan": True, "requiredByPlanReason": "DERIVATION_CLOSURE",
      "drvPath": "/nix/store/%032d-dep%03d.drv" % (i, i),
      "contentIdentity": {"storePath": sp, "expectedHash": "sha256-" + "A" * 42 + "=",
                          "expectedHashAlgo": "sha256", "hashMode": "nar"},
      "originHost": ({"value": None, "source": "UNKNOWN", "attrKey": None, "attrSite": None}
                     if unknown else
                     {"value": random.choice(hosts), "source": "URL_FALLBACK",
                      "attrKey": "url", "attrSite": "url"}),
      "owner": {"value": None, "source": "UNKNOWN", "attrKey": None, "attrSite": None},
      "repo": {"value": None, "source": "UNKNOWN", "attrKey": None, "attrSite": None},
      "rev": {"value": None, "source": "UNKNOWN", "attrKey": None, "attrSite": None},
      "tag": {"value": None, "source": "UNKNOWN", "attrKey": None, "attrSite": None},
      "aliasPaths": [], "discoveryStatus": "COVERED", "annotation": None})
json.dump({"schemaVersion": 1, "kind": "policy-governed-facts",
           "seedProvenance": "RECORDED",
           "flakeSource": {"storePath": "/nix/store/ffff-src", "narHash": None},
           "dependencies": deps}, open(sys.argv[1], "w"))
PYEOF
BIG=$TMP/corpus-big
nse_pg_corpus_generate "$TMP/big-seed.json" "$BIG" >/dev/null 2>&1
assert_eq "p25b.6 a RECORDED seed is labelled as evidence, not as a mechanism test" "1" \
  "$(jq -r '.meaning | test("is evidence") | if . then 1 else 0 end' "$BIG/SEED.json")"
assert_eq "p25b.7 the derived policy names a rule per observed host AND per unobserved source" "true" \
  "$(h=$(jq -r '[.dependencies[]|select(.originHost.source!="UNKNOWN")|.originHost.value]|unique|length' "$TMP/big-seed.json")
     u=$(jq -r '[.dependencies[]|select(.originHost.source=="UNKNOWN")|.contentIdentity.storePath]|unique|length' "$TMP/big-seed.json")
     r=$(grep -c '^\[\[rule\]\]' "$BIG/origin-moved/base/nix-source-escrow.toml")
     [ "$r" -eq "$((h+u))" ] && echo true || echo "false (hosts=$h unknown=$u rules=$r)")"
for fx in policy-self-exemption judge-replacement workflow-replacement \
          origin-moved policy-dependency-cochange; do
  bg=$TMP/big-$fx-ctl.json; hg=$TMP/big-$fx.json
  ( nse_pg_gate "$BIG/$fx/base" "$BIG/$fx/base" "$bg" base base ) >/dev/null 2>&1 || true
  ( nse_pg_gate "$BIG/$fx/base" "$BIG/$fx/head" "$hg" base head ) >/dev/null 2>&1 || true
  assert_eq "p25b.8 $fx on a 120-source recorded seed: control ACCEPTED" \
    "ACCEPTED" "$(jq -r .verdict "$bg")"
  assert_eq "p25b.9 $fx on a 120-source recorded seed: head REJECTED" \
    "REJECTED" "$(jq -r .verdict "$hg")"
done

head_ "p26  the control: every fixture accepts its own base state"
for fx in policy-self-exemption judge-replacement workflow-replacement \
          origin-moved policy-dependency-cochange; do
  r=$(gate_run "$fx" base)
  assert_eq "p26 control $fx: base gated against base is ACCEPTED" \
    "ACCEPTED" "$(jq -r .verdict "$r")"
done

head_ "p27  A. policy self-exemption -- C1"
A=$(gate_run policy-self-exemption head)
assert_eq "p27.1 the policy change is seen and named" "YES" "$(jq -r .POLICY_CHANGED "$A")"
assert_eq "p27.2 the ENFORCED policy is the BASE one" "base-policy-self-exemption" \
  "$(jq -r .ENFORCED_POLICY_COMMIT "$A")"
assert_ne "p27.3 and the proposed one is recorded separately, not merged in" \
  "$(jq -r .ENFORCED_POLICY_COMMIT "$A")" "$(jq -r .PROPOSED_POLICY_COMMIT "$A")"
assert_eq "p27.4 REJECTED, and by the base policy quarantining the added source" "REJECTED" \
  "$(jq -r .verdict "$A")"
assert_ne "p27.5 rejectedBy names QUARANTINED_DEPENDENCY" "0" \
  "$(jq -r '[.rejectedBy[] | select(. == "QUARANTINED_DEPENDENCY")] | length' "$A")"
# THE C1 EVIDENCE. The exemption the candidate wrote is REAL -- it would have
# let this dependency through -- and it did not, because it is not the policy
# that decided.
assert_eq "p27.6 under the ENFORCED policy the added source is quarantined" \
  "quarantine" \
  "$(jq -r '.decisions.decisions[] | select(.sourceId|test("vendorpkg")) | .effective.admission' "$A")"
assert_eq "p27.7 under the PROPOSED policy it would have been admitted normally" \
  "normal ignore" \
  "$(jq -r '.proposedPolicyPreview.wouldChangeVerdictsFor[] | select(.sourceId|test("vendorpkg")) | [.proposed.admission, .proposed.coverage] | join(" ")' "$A")"
assert_eq "p27.8 the preview says in the document that it decided nothing" "1" \
  "$(jq -r '[.proposedPolicyPreview.note | select(test("PREVIEW ONLY"))] | length' "$A")"

head_ "p28  B. judge replacement -- C2"
B=$(gate_run judge-replacement head)
assert_eq "p28.1 JUDGE_MISMATCH, and it is the ONLY reason for the rejection" \
  '["JUDGE_MISMATCH"]' "$(jq -c .rejectedBy "$B")"
assert_ne "p28.2 the trusted judge sha is recorded" "" "$(jq -r .judge.trustedSha256 "$B")"
assert_ne "p28.3 and differs from the candidate one" \
  "$(jq -r .judge.trustedSha256 "$B")" "$(jq -r .judge.candidateSha256 "$B")"
assert_eq "p28.4 the report states, as a field, that the candidate judge was not executed" \
  "false" "$(jq -r .judge.candidateJudgeExecuted "$B")"
assert_eq "p28.5 and it names WHICH file differs, not merely that one does" \
  "bin/nse-pg" \
  "$(jq -r '.findings[] | select(.id=="JUDGE_MISMATCH") | .differingFiles[].path' "$B")"
# The candidate judge says PASS. Nothing in the verdict came from it.
assert_ne "p28.6 the malicious judge really would have said PASS" "0" \
  "$(grep -c 'echo PASS' "$CORPUS/judge-replacement/head/bin/nse-pg" || true)"
assert_eq "p28.7 and the verdict is REJECTED all the same" "REJECTED" "$(jq -r .verdict "$B")"
# DELETING the judge must not be quieter than editing it.
rm -rf "$TMP/nojudge"; cp -r "$CORPUS/judge-replacement/head" "$TMP/nojudge"
rm -f "$TMP/nojudge/bin/nse-pg"
Bd=$TMP/gate-nojudge.json
( nse_pg_gate "$CORPUS/judge-replacement/base" "$TMP/nojudge" "$Bd" base head ) >/dev/null 2>&1 || true
assert_eq "p28.8 DELETING the judge is a mismatch too, not an absence that passes" \
  '["JUDGE_MISMATCH"]' "$(jq -c .rejectedBy "$Bd")"

head_ "p29  C. workflow replacement"
C=$(gate_run workflow-replacement head)
assert_eq "p29.1 WORKFLOW_MISMATCH, and nothing else" \
  '["WORKFLOW_MISMATCH"]' "$(jq -c .rejectedBy "$C")"
assert_ne "p29.2 the trusted workflow identity is recorded" \
  "$(jq -r .workflow.trustedIdentity "$C")" "$(jq -r .workflow.candidateIdentity "$C")"
assert_ne "p29.3 the finding says out loud that this is a check of the MODEL" "0" \
  "$(jq -r '[.findings[] | select(.id=="WORKFLOW_MISMATCH") | select(.detail | test("check of the MODEL"))] | length' "$C")"
# ADDING a workflow must move the identity. Comparing each root only against
# its own file list would let a candidate add one and keep a matching identity.
rm -rf "$TMP/addwf"; cp -r "$CORPUS/workflow-replacement/base" "$TMP/addwf"
printf 'name: extra\non: [push]\njobs: {}\n' > "$TMP/addwf/.github/workflows/extra.yml"
Cw=$TMP/gate-addwf.json
( nse_pg_gate "$CORPUS/workflow-replacement/base" "$TMP/addwf" "$Cw" base head ) >/dev/null 2>&1 || true
assert_eq "p29.4 ADDING a workflow is a mismatch too" \
  '["WORKFLOW_MISMATCH"]' "$(jq -c .rejectedBy "$Cw")"

head_ "p30  D. same content, new origin -- C3"
D=$(gate_run origin-moved head)
assert_eq "p30.1 the three registered tokens, together" \
  "UNCHANGED CHANGED ORIGIN_MOVED_OR_FACTS_CHANGED" \
  "$(jq -r '[.digests.dependencyContent, .digests.policyFacts, .digests.shape] | join(" ")' "$D")"
assert_ne "p30.2 ORIGIN_MOVED is reported as a finding" "0" \
  "$(jq -r '[.findings[] | select(.id == "ORIGIN_MOVED")] | length' "$D")"
assert_eq "p30.3 policy RE-EVALUATED: the same policy reached a different decision" \
  "CHANGED" "$(jq -r .digests.effectiveDecision "$D")"
# Asserted as a PROPERTY, not as a rule name. The corpus is generated from a
# seed and its policy is derived from that seed, so a literal rule id here
# would be an assertion about the synthetic seed rather than about the
# mechanism -- and would go red the moment the corpus ran on a recorded one.
Dbase=$(gate_run origin-moved base)
moved_id=$(jq -r '.movedDependency' "$CORPUS/SEED.json")
assert_ne "p30.4 the moved dependency WAS covered by a rule before the move" "" \
  "$(jq -r --arg id "$moved_id" '.decisions.decisions[] | select(.sourceId == $id) | .matchedRuleIds | join(",")' "$Dbase")"
assert_eq "p30.4a and matches nothing after it -- it lost the rule that covered it" "" \
  "$(jq -r --arg id "$moved_id" '.decisions.decisions[] | select(.sourceId == $id) | .matchedRuleIds | join(",")' "$D")"
assert_eq "p30.4b so its admission falls to the policy DEFAULT, which is quarantine" \
  "quarantine DEFAULT" \
  "$(jq -r --arg id "$moved_id" '.decisions.decisions[] | select(.sourceId == $id) | [.effective.admission, .axisSource.admission] | join(" ")' "$D")"
assert_eq "p30.5 and is rejected, on the strength of a fact a content hash cannot carry" \
  '["QUARANTINED_DEPENDENCY"]' "$(jq -c .rejectedBy "$D")"
# The bytes really are identical. If they were not, this fixture would be
# demonstrating something much less interesting.
assert_eq "p30.6 the moved dependency keeps its expectedHash, byte for byte" \
  "$(jq -r '.dependencies[0].contentIdentity.expectedHash' "$CORPUS/origin-moved/base/facts.json")" \
  "$(jq -r '.dependencies[0].contentIdentity.expectedHash' "$CORPUS/origin-moved/head/facts.json")"
assert_eq "p30.7 and its storePath" \
  "$(jq -r '.dependencies[0].contentIdentity.storePath' "$CORPUS/origin-moved/base/facts.json")" \
  "$(jq -r '.dependencies[0].contentIdentity.storePath' "$CORPUS/origin-moved/head/facts.json")"

head_ "p31  E. policy and dependency in one proposal"
E=$(gate_run policy-dependency-cochange head)
assert_eq "p31.1 POLICY_DEPENDENCY_COCHANGE, and it is the ONLY rejection" \
  '["POLICY_DEPENDENCY_COCHANGE"]' "$(jq -c .rejectedBy "$E")"
assert_eq "p31.2 the added dependency is named" "1" \
  "$(jq -r '[.findings[] | select(.id=="POLICY_DEPENDENCY_COCHANGE") | .affected[]] | length' "$E")"
# The WEAKENING, asserted as a direction on the axis rather than as two
# literal words: the proposal moves the added dependency DOWN the coverage
# order, which is the whole reason the conjunction is refused.
assert_eq "p31.3 the proposal would move the added dependency DOWN the coverage axis" \
  "true" \
  "$(jq -r '.findings[] | select(.id=="POLICY_DEPENDENCY_COCHANGE") | .affected[]
            | . as $a | ["ignore","auto","required"] as $ord
            # `. as $a` FIRST. `$ord | index(.proposed.coverage)` rebinds . to
            # the array, so .proposed indexes the ORDER LIST -- the third time
            # this exact trap has appeared in this line, and the third time jq
            # refused outright rather than answering wrongly.
            | (($ord | index($a.proposed.coverage)) < ($ord | index($a.enforced.coverage)))' "$E")"
assert_eq "p31.3a and the proposed value is the exemption the candidate wrote" "ignore" \
  "$(jq -r '.findings[] | select(.id=="POLICY_DEPENDENCY_COCHANGE") | .affected[] | .proposed.coverage' "$E")"
# THE SPECIMEN TEST. If this fixture were red for some other reason, deleting
# the cochange guard would leave it red and the guard would be untested.
assert_eq "p31.4 the added dependency is, on its own, perfectly acceptable to the base policy" \
  "accepted" \
  "$(jq -r '.decisions.decisions[] | select(.sourceId|test("newlib")) | .acceptance' "$E")"
# A policy change with NO affected added dependency is NOT a cochange.
rm -rf "$TMP/polonly"; cp -r "$CORPUS/policy-dependency-cochange/head" "$TMP/polonly"
cp "$CORPUS/policy-dependency-cochange/base/facts.json" "$TMP/polonly/facts.json"
Ep=$TMP/gate-polonly.json
( nse_pg_gate "$CORPUS/policy-dependency-cochange/base" "$TMP/polonly" "$Ep" base head ) >/dev/null 2>&1 || true
assert_eq "p31.5 a policy change ALONE is not a cochange -- the guard is narrow, not eager" \
  "[]" "$(jq -c .rejectedBy "$Ep")"
assert_eq "p31.6 and the policy change is still reported" "YES" "$(jq -r .POLICY_CHANGED "$Ep")"

head_ "p32  the gate refuses rather than improvising"
# A trusted root with no policy must not fall back to the candidate copy --
# which is the exact substitution this whole design exists to prevent.
rm -rf "$TMP/nopolicy"; cp -r "$CORPUS/judge-replacement/base" "$TMP/nopolicy"
rm -f "$TMP/nopolicy/nix-source-escrow.toml"
rc=0; ( nse_pg_gate "$TMP/nopolicy" "$CORPUS/judge-replacement/head" "$TMP/x.json" a b ) >/dev/null 2>"$TMP/nopolicy.err" || rc=$?
assert_eq "p32.1 a trusted root with no policy is a CHECKER_ERROR (3), not a lenient pass" "3" "$rc"
assert_ne "p32.2 and the refusal names the substitution it is refusing" "0" \
  "$(grep -c 'candidate' "$TMP/nopolicy.err" || true)"
# No base facts -> POLICY_DEPENDENCY_COCHANGE cannot be evaluated at all, and
# an unevaluable guard must not read as a guard that passed.
rm -rf "$TMP/nobase"; cp -r "$CORPUS/judge-replacement/base" "$TMP/nobase"
rm -f "$TMP/nobase/facts.json"
rc=0; ( nse_pg_gate "$TMP/nobase" "$CORPUS/judge-replacement/head" "$TMP/y.json" a b ) >/dev/null 2>/dev/null || rc=$?
assert_eq "p32.3 no base graph is a CHECKER_ERROR, not an empty set of added dependencies" "3" "$rc"

# ---------------------------------------------------------------------------
head_ "p33  the join from a real discovery document to facts"
# The Nix half of lib/pg-ingest.sh runs only in CI. The MAPPING DECISIONS live
# in the join, and a mapping that can only be tested in CI is a mapping nobody
# re-tests -- so the join takes files and is exercised here, against a document
# shaped the way lib/discover.sh actually emits one.
DISC=$ROOT/tests/pg-fixtures/discovery-shape.json
DRVF=$ROOT/tests/pg-fixtures/drv-facts-shape.json
printf '%s\n' /nix/store/abcd0000000000000000000000000000-nix-pills-src.drv \
               /nix/store/tttt0000000000000000000000000000-escrow-fixture-0.1.drv > "$TMP/req.txt"
J=$TMP/joined.json
nse_pg_facts_join "$DISC" "$DRVF" "$TMP/req.txt" DERIVATION_CLOSURE "nix 2.34.7" envelope "inst" > "$J"
assert_eq "p33.1 both classes arrive" "flake-input,fod,fod" \
  "$(jq -r '[.dependencies[].class] | join(",")' "$J")"
assert_eq "p33.2 a flake input carries LOCK_ATTR provenance, not DERIVATION_ATTR" \
  "LOCK_ATTR LOCK_ATTR LOCK_ATTR" \
  "$(jq -r '.dependencies[] | select(.class=="flake-input") | [.owner.source,.repo.source,.rev.source] | join(" ")' "$J")"
assert_eq "p33.3 and says WHY it is required, rather than merely that it is" \
  "true FLAKE_EVALUATION_INPUT" \
  "$(jq -r '.dependencies[] | select(.class=="flake-input") | [(.requiredByPlan|tostring), .requiredByPlanReason] | join(" ")' "$J")"
assert_eq "p33.4 a source WITH attribute facts gets them, with provenance" \
  "NixOS DERIVATION_ATTR github.com URL_FALLBACK" \
  "$(jq -r '.dependencies[] | select(.kind=="fetchzip-like") | [.owner.value,.owner.source,.originHost.value,.originHost.source] | join(" ")' "$J")"
# THE IMPORTANT ONE. A derivation the attribute reader has no entry for must
# yield UNKNOWN facts -- not absent keys, and above all not facts borrowed from
# whichever neighbour happened to be nearby.
assert_eq "p33.5 a source with NO attribute-reader entry is UNKNOWN, not its neighbour" \
  "UNKNOWN UNKNOWN UNKNOWN UNKNOWN" \
  "$(jq -r '.dependencies[] | select(.kind=="no-fetcher") | [.owner.source,.repo.source,.rev.source,.originHost.source] | join(" ")' "$J")"
assert_eq "p33.6 requiredByPlan is read from the requisite set, per source" \
  "true false" \
  "$(jq -r '[.dependencies[] | select(.class=="fod") | .requiredByPlan | tostring] | join(" ")' "$J")"
# THE FAIL-CLOSED ONE. An unobserved requiredByPlan must be null, not false --
# `auto` coverage plus a false is a silent exemption granted by an instrument.
: > "$TMP/req-empty.txt"
JN=$TMP/joined-unobserved.json
nse_pg_facts_join "$DISC" "$DRVF" "$TMP/req-empty.txt" NOT_OBSERVED "nix 2.34.7" envelope "inst" > "$JN"
assert_eq "p33.7 an UNOBSERVED requiredByPlan is null, never false" \
  "null null" \
  "$(jq -r '[.dependencies[] | select(.class=="fod") | .requiredByPlan | tostring] | join(" ")' "$JN")"
POL_A2=$(printf '%s\n' '[defaults]' 'coverage = "auto"' | policy_of rev-test)
DU=$(decide_with "$POL_A2" "$JN")
assert_eq "p33.8 and it makes mustPreserve UNDECIDED rather than false" "2" \
  "$(jq -r '[.decisions[] | select(.class=="fod") | select(.mustPreserve == null)] | length' "$DU")"
assert_eq "p33.9 the document declares itself RECORDED, not synthetic" "RECORDED" \
  "$(jq -r .seedProvenance "$J")"
assert_eq "p33.10 the digests are computable over it, and differ from each other" "false" \
  "$(nse_pg_digests "$J" | jq -r '.dependencyContentDigest == .policyFactsDigest')"

head_ "p33b  the drv-facts map compiles, and reads the annotation"
# THE REASON THIS TEST EXISTS. This jq lived only on a CI-only code path and
# called `nse_pg_attr` where the helper is named `nse_attr`. jq refused to
# compile it, the facts step died four steps into a run, and the only notice
# was a red job. A jq program reachable only from CI is a jq program whose
# first typo costs a whole cycle.
jq -n '{"a.drv":{name:"x",
                 env:{owner:"NixOS",repo:"b",
                      urls:"https://github.com/NixOS/b/archive/x.tar.gz",
                      nseEscrowCoverage:"required"},
                 outputs:{out:{hash:"sha256-A="}}},
        "b.drv":{name:"y",
                 env:{urls:"https://ftp.gnu.org/x.tar.gz"},
                 outputs:{out:{hash:"sha256-B="}}}}' > "$TMP/drvmap.json"
DM=$(nse_pg_drv_facts_map "$TMP/drvmap.json")
assert_eq "p33b.1 it compiles and covers every derivation" "2" \
  "$(printf '%s' "$DM" | jq 'length')"
assert_eq "p33b.2 the annotation VALUE is read, not merely its presence" "required" \
  "$(printf '%s' "$DM" | jq -r '.["a.drv"].annotationCoverage')"
assert_eq "p33b.3 an unannotated derivation reports null, not the neighbour value" "null" \
  "$(printf '%s' "$DM" | jq -r '.["b.drv"].annotationCoverage | tostring')"
assert_eq "p33b.4 and the facts come with provenance" "NixOS DERIVATION_ATTR" \
  "$(printf '%s' "$DM" | jq -r '.["a.drv"].facts.owner | [.value,.source] | join(" ")')"
assert_eq "p33b.5 the annotation key appears in attrKeys too" "true" \
  "$(printf '%s' "$DM" | jq -r '(.["a.drv"].attrKeys | index("nseEscrowCoverage")) != null')"

head_ "p34  the untrusted phase runs local, ephemeral and credential-free"
# The preflight is pure -- paths, URLs and environment names in, findings out --
# so the invariants that bound the untrusted phase can be re-checked by anyone
# on any machine in a second, without a Nix or a store.
# `env -i`, not `unset` in a subshell. THIS container has AWS_ACCESS_KEY_ID,
# GH_TOKEN and two more in the ambient environment, so a test that merely
# unsets the ones it knows about measures the machine it happens to run on.
# A clean environment is constructed, never assumed.
clean_env() {  # clean_env <shell-snippet>
  # shellcheck disable=SC2016  # the bash -c program is deliberately unexpanded
  env -i PATH="$PATH" HOME="${HOME:-/root}" TMPDIR="$TMP" NSE_ROOT="$ROOT" \
    bash -c '. "$NSE_ROOT/lib/common.sh"; . "$NSE_ROOT/lib/pg-common.sh"
             . "$NSE_ROOT/lib/pg-scratch.sh"; eval "$1"' _ "$1"
}
pf() { clean_env "nse_pg_scratch_preflight '$1' '$2' '$3'"; }
assert_eq "p34.1 a local store inside the scratch dir is CLEARED" "CLEARED" \
  "$(pf /tmp/sc "file:///tmp/sc/cache?compression=zstd" escrow-replay | jq -r .verdict)"
assert_eq "p34.2 an s3:// destination is REFUSED, and named NOT_LOCAL" "REFUSED NOT_LOCAL" \
  "$(pf /tmp/sc "s3://a-bucket" escrow-replay | jq -r '[.verdict, .findings[0].id] | join(" ")')"
assert_eq "p34.3 an ssh-ng:// destination too" "REFUSED NOT_LOCAL" \
  "$(pf /tmp/sc "ssh-ng://builder" escrow-replay | jq -r '[.verdict, .findings[0].id] | join(" ")')"
assert_eq "p34.4 a LOCAL path outside the scratch dir is durable storage with a shorter name" \
  "REFUSED NOT_EPHEMERAL" \
  "$(pf /tmp/sc "file:///srv/escrow" escrow-replay | jq -r '[.verdict, .findings[0].id] | join(" ")')"
assert_eq "p34.5 an unnamed guarantee cannot be run at all" "REFUSED GUARANTEE_UNNAMED" \
  "$(pf /tmp/sc "file:///tmp/sc/cache" FULL_AIRGAP_REBUILD | jq -r '[.verdict, .findings[0].id] | join(" ")')"
# A credential in reach, NAMED.
# shellcheck disable=SC2016  # the bash -c program is deliberately unexpanded
cred=$(env -i PATH="$PATH" HOME="${HOME:-/root}" TMPDIR="$TMP" NSE_ROOT="$ROOT" \
        AWS_SECRET_ACCESS_KEY=hunter2 \
        bash -c '. "$NSE_ROOT/lib/common.sh"; . "$NSE_ROOT/lib/pg-common.sh"
                 . "$NSE_ROOT/lib/pg-scratch.sh"
                 nse_pg_scratch_preflight /tmp/sc "file:///tmp/sc/cache" escrow-replay')
assert_eq "p34.6 a credential in reach is REFUSED" "REFUSED" "$(printf '%s' "$cred" | jq -r .verdict)"
assert_eq "p34.7 and it is NAMED, not counted" "AWS_SECRET_ACCESS_KEY" \
  "$(printf '%s' "$cred" | jq -r '.credentialsInReach | join(",")')"

head_ "p35  the scrub is a side effect, so it must not run in a subshell"
# THE DEFECT THIS TEST EXISTS FOR. The first version returned the scrubbed list
# on stdout, every caller wrote `x=$(nse_pg_scrub_credentials)`, and a command
# substitution is a SUBSHELL: the unsets happened in a child that exited, the
# parent kept every credential, and the function reported having removed four.
# It printed the right answer and did nothing -- which is worse than doing
# nothing, because the report says the property holds.
# shellcheck disable=SC2016  # the bash -c program is deliberately unexpanded
scrub_check=$(env -i PATH="$PATH" HOME="${HOME:-/root}" NSE_ROOT="$ROOT" \
        AWS_SECRET_ACCESS_KEY=hunter2 GITHUB_TOKEN=ghp_x \
        bash -c '. "$NSE_ROOT/lib/common.sh"; . "$NSE_ROOT/lib/pg-common.sh"
                 . "$NSE_ROOT/lib/pg-scratch.sh"
                 nse_pg_scrub_credentials
                 printf "%s|%s|%s" "$NSE_PG_SCRUBBED" "${AWS_SECRET_ACCESS_KEY:-GONE}" "${GITHUB_TOKEN:-GONE}"')
assert_eq "p35.1 the names come back AND the variables are actually gone" \
  "AWS_SECRET_ACCESS_KEY GITHUB_TOKEN|GONE|GONE" "$scrub_check"
# The red control: the broken shape, demonstrated, so the assertion above is
# known to be capable of failing.
# shellcheck disable=SC2016  # the bash -c program is deliberately unexpanded
subshell_check=$(env -i PATH="$PATH" HOME="${HOME:-/root}" NSE_ROOT="$ROOT" \
        AWS_SECRET_ACCESS_KEY=hunter2 \
        bash -c '. "$NSE_ROOT/lib/common.sh"; . "$NSE_ROOT/lib/pg-common.sh"
                 . "$NSE_ROOT/lib/pg-scratch.sh"
                 discard=$( nse_pg_scrub_credentials )
                 printf "%s" "${AWS_SECRET_ACCESS_KEY:-GONE}"')
assert_eq "p35.2 red control: called inside \$( ), the unset does NOT survive" \
  "hunter2" "$subshell_check"

head_ "p36  the check name states the guarantee, always"
assert_eq "p36.1 the strong one" "ESCROW_REPLAY PASS" "$(nse_pg_check_name escrow-replay PASS)"
assert_eq "p36.2 the weaker one, named so nobody confuses the two" \
  "SOURCE_ORIGIN_INDEPENDENCE FAIL" "$(nse_pg_check_name source-origin-independence FAIL)"
rc=0; ( nse_pg_check_name "source escrow" PASS ) >/dev/null 2>&1 || rc=$?
assert_eq "p36.3 an unnamed guarantee cannot be given a check name" "3" "$rc"
# A comment may NAME the forbidden phrase -- lib/pg-scratch.sh does, in the
# passage explaining why it is forbidden. An EMITTED line may not. Anchoring at
# the start of a non-comment line is what separates the two, exactly as u07
# does for a hardcoded host in the closed line.
assert_eq "p36.4 no non-comment line can emit the bare phrase this line forbids" "" \
  "$(grep -REn '^[^#]*Source escrow (PASS|FAIL)' "$ROOT/lib" "$ROOT/bin" || true)"
assert_ne "p36.4a positive control: such a line WOULD be caught" "0" \
  "$(printf '%s\n' 'printf "Source escrow PASS"' | grep -cE '^[^#]*Source escrow (PASS|FAIL)' || true)"
assert_eq "p36.4b and a comment naming it is NOT caught" "" \
  "$(printf '%s\n' '#   Source escrow PASS' | grep -E '^[^#]*Source escrow (PASS|FAIL)' || true)"

head_ "p37  the summary says what it does NOT establish, on every run"
SUM=$TMP/summary.txt
nse_pg_summary "$TMP/gate-judge-replacement-head.json" > "$SUM"
assert_ne "p37.1 the verdict is in it" "0" "$(grep -c '^VERDICT: REJECTED' "$SUM" || true)"
assert_ne "p37.2 the enforced policy revision is in it" "0" "$(grep -c 'enforced from:' "$SUM" || true)"
# EVERY control is listed, including the ones that did not fire. Binding an
# empty jq stream with `as` produces no output, so the first version silently
# dropped every untriggered control -- and a list of only the guards that fired
# cannot say a guard was considered and found nothing.
assert_eq "p37.3 every adversarial control is listed, fired or not" "6" \
  "$(awk '/^Adversarial controls:/{f=1;next} f&&/^$/{exit} f' "$SUM" | grep -c ':' || true)"
assert_ne "p37.4 including ones that did not trigger" "0" \
  "$(grep -c 'not triggered' "$SUM" || true)"
# The disclosure is at the BOTTOM, where a reader who stops early has already
# passed the verdict -- and it is printed on green runs too.
assert_ne "p37.5 the non-claims are present" "0" \
  "$(grep -c 'What this does NOT establish' "$SUM" || true)"
assert_ne "p37.6 and they name GitHub-level judge independence" "0" \
  "$(grep -c 'judge independence' "$SUM" || true)"
assert_ne "p37.7 and durable promotion" "0" "$(grep -c 'durable promotion' "$SUM" || true)"
assert_eq "p37.8 the disclosure comes AFTER the verdict, not before it" "true" \
  "$(v=$(grep -n '^VERDICT:' "$SUM" | cut -d: -f1); d=$(grep -n 'What this does NOT establish' "$SUM" | cut -d: -f1); [ "$d" -gt "$v" ] && echo true || echo false)"
# A run with no acceptance test must not imply one happened.
assert_ne "p37.9 no acceptance test means no guarantee is claimed" "0" \
  "$(grep -c 'no guarantee is claimed' "$SUM" || true)"
# The green case must carry the disclosure too. Especially the green case.
SUMG=$TMP/summary-green.txt
nse_pg_summary "$TMP/gate-judge-replacement-base.json" > "$SUMG"
assert_ne "p37.10 an ACCEPTED run carries the same disclosure" "0" \
  "$(grep -c 'What this does NOT establish' "$SUMG" || true)"
assert_ne "p37.11 and still says the verdict" "0" "$(grep -c '^VERDICT: ACCEPTED' "$SUMG" || true)"

# ---------------------------------------------------------------------------
head_ "p38  CACH5: a cached verdict is seen, named, and not read"
# The one that matters most. A shared cache may hold content-addressed BYTES,
# which anyone can re-verify against a hash. It may not hold CONCLUSIONS about
# them, which can only be believed.
CJ=$CORPUS/judge-replacement
rm -rf "$TMP/cached"; cp -r "$CJ/head" "$TMP/cached"
# The candidate plants its own verdict, in its own tree, saying it passed.
printf '%s\n' '{"verdict":"ACCEPTED","rejectedBy":[],"findings":[]}' > "$TMP/cached/gate-report.json"
printf '%s\n' '{"decisions":[],"counts":{"quarantined":0,"undecided":0,"ruleConflicts":0,"policyConflicts":0,"dependencies":0,"mustPreserve":0}}' \
  > "$TMP/cached/decisions.json"
mkdir -p "$TMP/cached/escrow/evidence"
printf '%s\n' '{"result":"PASS"}' > "$TMP/cached/escrow/evidence/origin-independence.json"
CG=$TMP/gate-cached.json
( nse_pg_gate "$CJ/base" "$TMP/cached" "$CG" base head ) >/dev/null 2>&1 || true
assert_eq "p38.1 the planted verdicts are FOUND -- silence is not the same as absence" \
  "decisions.json,escrow/evidence/origin-independence.json,gate-report.json" \
  "$(jq -r '.cache.cachedVerdictArtifactsFound | sort | join(",")' "$CG")"
assert_eq "p38.2 and none of them was read" "[]" \
  "$(jq -c '.cache.cachedVerdictArtifactsRead' "$CG")"
assert_eq "p38.3 the report states that the decisions were recomputed" "true" \
  "$(jq -r .cache.decisionsRecomputed "$CG")"
assert_eq "p38.4 the candidate said ACCEPTED; the trusted judge says otherwise" "REJECTED" \
  "$(jq -r .verdict "$CG")"
assert_eq "p38.5 for the reason the trusted judge computed, not the one supplied" \
  '["JUDGE_MISMATCH"]' "$(jq -c .rejectedBy "$CG")"
# THE PROOF, rather than the assertion: the same run WITHOUT the planted files
# reaches an identical verdict and identical decisions.
NOCACHE=$TMP/gate-nocache.json
( nse_pg_gate "$CJ/base" "$CJ/head" "$NOCACHE" base head ) >/dev/null 2>&1 || true
assert_eq "p38.6 the decisions are byte-identical with and without the planted verdicts" \
  "$(jq -Sc '.decisions' "$NOCACHE")" "$(jq -Sc '.decisions' "$CG")"
assert_eq "p38.7 and so is the rejection" \
  "$(jq -Sc '[.verdict, .rejectedBy]' "$NOCACHE")" "$(jq -Sc '[.verdict, .rejectedBy]' "$CG")"
# The finding is INFO: a cached artifact is not itself a wrong. Reading one
# would be.
assert_eq "p38.8 finding it is INFO, not a rejection -- having one is not the offence" \
  "INFO" "$(jq -r '.findings[] | select(.id=="CACHED_VERDICT_IGNORED") | .severity' "$CG")"
assert_eq "p38.9 a clean candidate reports no cached verdicts at all" "[]" \
  "$(jq -c '.cache.cachedVerdictArtifactsFound' "$NOCACHE")"

head_ "p39  CACH3: the acceptance store starts empty, observed rather than assumed"
SC=$TMP/scratchdir
rm -rf "$SC"; mkdir -p "$SC/cache" "$SC/work/staging"
printf 'leftover from a previous run\n' > "$SC/cache/deadbeef.narinfo"
printf 'more leftovers\n' > "$SC/work/staging/junk"
nse_pg_scratch_prepare "$SC"
assert_eq "p39.1 the leftovers were counted, not ignored" "true" \
  "$([ "${NSE_PG_SCRATCH_WIPED:-0}" -ge 4 ] && echo true || echo false)"
assert_eq "p39.2 and the store is empty afterwards" "0" \
  "$(find "$SC" -mindepth 1 | wc -l | tr -d ' ')"
nse_pg_scratch_prepare "$SC"
assert_eq "p39.3 preparing an already-empty store removes nothing" "0" "${NSE_PG_SCRATCH_WIPED:-x}"
# THE REFUSAL PATH, and an honest account of what can be constructed here.
#
# nse_pg_scratch_prepare has two failure branches:
#
#   (a) the directory cannot be CREATED          -- constructible, tested below
#   (b) it was created but is not empty afterwards
#
# Branch (b) is real -- an immutable-flagged file, a busy mount point, a
# filesystem error -- and it has no portable specimen a unit suite can build
# without privileges: the function chmods the tree writable before removing it,
# which is correct behaviour (a Nix store path is read-only by construction and
# would otherwise be unremovable), and that same chmod defeats every
# permission-based specimen. Two earlier attempts at one were wrong in exactly
# that way, and both times the CODE was right and the test was not.
#
# EXPERIMENT-PROTOCOL.md §1 asks for the observable trace that would make a
# check report failure. It is describable, and it is stated here rather than
# faked with a specimen that does not reproduce it.
rm -rf "$TMP/blocked"; : > "$TMP/blocked"      # a FILE where a directory must go
rc=0; nse_pg_scratch_prepare "$TMP/blocked/scratch" || rc=$?
assert_ne "p39.4 a scratch store that cannot be CREATED is a failure" "0" "$rc"
rm -f "$TMP/blocked"
if [ "$(id -u)" -eq 0 ]; then
  echo "  skipped p39.5 (running as root: permission bits do not apply)"
else
  # What a read-only tree DOES do: get force-removed. That is the behaviour a
  # Nix staging store needs -- its paths are read-only by construction -- so it
  # is asserted rather than merely relied on.
  rm -rf "$TMP/locked"; mkdir -p "$TMP/locked/keep"; : > "$TMP/locked/keep/file"
  chmod 500 "$TMP/locked/keep"
  rc=0; nse_pg_scratch_prepare "$TMP/locked" || rc=$?
  chmod 700 "$TMP/locked/keep" 2>/dev/null || :
  assert_eq "p39.5 a read-only subtree is force-removed, as a Nix store requires" "0" "$rc"
  assert_eq "p39.5a and the store really is empty afterwards" "0" \
    "$(find "$TMP/locked" -mindepth 1 2>/dev/null | wc -l | tr -d " ")"
fi

head_ "p40  CACH1 / CACH4: only the cost may move"
mkcost() { jq -n --arg r "$1" --argjson e "$2" --argjson ms "$3" \
  '{checkName: ("ESCROW_REPLAY " + $r), result: $r, exitCode: $e, guarantee: "escrow-replay", elapsedMilliseconds: $ms}'; }
mkcost PASS 0 120000 > "$TMP/cold.json"
mkcost PASS 0 9000   > "$TMP/warm.json"
CMP=$(nse_pg_cache_compare "$TMP/cold.json" "$TMP/warm.json")
assert_eq "p40.1 same verdict cold and warm: semantics unchanged" "true" \
  "$(printf '%s' "$CMP" | jq -r .CACH1_semanticsUnchanged)"
assert_eq "p40.2 and the only thing that moved is the clock" "true" \
  "$(printf '%s' "$CMP" | jq -r .CACH4_onlyCostMoved)"
assert_ne "p40.3 the speedup is reported, because cost is part of the product" "null" \
  "$(printf '%s' "$CMP" | jq -r '.speedup | tostring')"
# THE RED CONTROL. A warm run that reaches a DIFFERENT verdict is a cache that
# changed what the run means, and this comparison must say so.
mkcost FAIL 1 9000 > "$TMP/warm-bad.json"
BAD=$(nse_pg_cache_compare "$TMP/cold.json" "$TMP/warm-bad.json")
assert_eq "p40.4 red control: a warm run with a different verdict is NOT unchanged" "false" \
  "$(printf '%s' "$BAD" | jq -r .CACH1_semanticsUnchanged)"
# A warm run that keeps the verdict but changes the GUARANTEE is also a change.
jq '.guarantee = "source-origin-independence" | .checkName = "SOURCE_ORIGIN_INDEPENDENCE PASS"' \
  "$TMP/warm.json" > "$TMP/warm-guarantee.json"
BADG=$(nse_pg_cache_compare "$TMP/cold.json" "$TMP/warm-guarantee.json")
assert_eq "p40.5 red control: a changed GUARANTEE is a changed meaning, same verdict or not" "false" \
  "$(printf '%s' "$BADG" | jq -r .CACH1_semanticsUnchanged)"

head_ "p41  CACH2: a corrupt cache cannot become evidence"
# The policy half, testable here. The store half is measured in CI, where
# there is a store to corrupt.
rm -rf "$TMP/corrupt"; cp -r "$CJ/head" "$TMP/corrupt"
printf 'this is not json {{{\n' > "$TMP/corrupt/facts.json"
rc=0; ( nse_pg_gate "$CJ/base" "$TMP/corrupt" "$TMP/corrupt-report.json" base head ) >/dev/null 2>&1 || rc=$?
assert_eq "p41.1 an unreadable candidate graph is a CHECKER_ERROR (3), not an empty one" "3" "$rc"
# And an empty one is not a graph with nothing in it either.
rm -rf "$TMP/emptyfacts"; cp -r "$CJ/head" "$TMP/emptyfacts"
printf '{"schemaVersion":1,"kind":"policy-governed-facts","flakeSource":{"storePath":null,"narHash":null},"dependencies":[]}\n' \
  > "$TMP/emptyfacts/facts.json"
EF=$TMP/emptyfacts-report.json
( nse_pg_gate "$CJ/base" "$TMP/emptyfacts" "$EF" base head ) >/dev/null 2>&1 || true
assert_eq "p41.2 a graph with zero dependencies still gets a verdict, and it is not silence" \
  "REJECTED" "$(jq -r .verdict "$EF")"
assert_eq "p41.3 the judge mismatch is still what rejects it -- 0 of 0 did not go green" \
  '["JUDGE_MISMATCH"]' "$(jq -c .rejectedBy "$EF")"

# ---------------------------------------------------------------------------
head_ "p43  the gate runs on a real checkout, not only on fixtures"
# Two copies of THIS repository's own tool files, with the graph handed in from
# outside -- which is the shape a real deployment has, because a checkout does
# not carry a committed facts.json. Without this, every assertion above would
# be about a directory layout invented for the tests.
mkreal() {
  local d=$1 r
  rm -rf "$d"; mkdir -p "$d/bin" "$d/lib" "$d/.github/workflows"
  cp "$ROOT/bin/nse-pg" "$d/bin/"
  for r in "$ROOT"/lib/pg-*.sh; do cp "$r" "$d/lib/"; done
  cp "$ROOT/nix-source-escrow.toml" "$d/"
  cp "$ROOT/.github/workflows/policy-governed.yml" "$d/.github/workflows/"
}
mkreal "$TMP/real-base"; mkreal "$TMP/real-head"
RG=$TMP/real-gate.json
( nse_pg_gate "$TMP/real-base" "$TMP/real-head" "$RG" base head \
    "$ROOT/tests/pg-fixtures/facts-seed.json" "$ROOT/tests/pg-fixtures/facts-seed.json" ) \
  >/dev/null 2>&1 || true
assert_eq "p43.1 an unmodified checkout against itself is ACCEPTED" "ACCEPTED" \
  "$(jq -r .verdict "$RG")"
assert_eq "p43.2 the judge identity matches, over the REAL tool files" "true" \
  "$(jq -r '.judge.trustedSha256 == .judge.candidateSha256' "$RG")"
# THE FILE-SET GUARD, and the defect it found. The judge file set used to be
# six names typed by hand; seven more lib/pg-*.sh files were added afterwards
# and none reached the list, so the matcher, the cache guard and the summary
# that renders the verdict were all editable without moving the identity. It is
# discovered now, not maintained.
assert_eq "p43.3 every lib/pg-*.sh in this repo is part of the hashed judge" "" \
  "$(known=$(nse_pg_judge_files "$ROOT")
     for f in "$ROOT"/lib/pg-*.sh; do
       rel=lib/$(basename "$f")
       printf '%s\n' "$known" | grep -qx "$rel" || printf '%s ' "$rel"
     done)"
assert_eq "p43.4 and the executable itself is" "1" \
  "$(nse_pg_judge_files "$ROOT" | grep -cx 'bin/nse-pg' || true)"
assert_eq "p43.4a the set really is discovered, and covers every one of them" \
  "$(find "$ROOT/lib" -maxdepth 1 -name 'pg-*.sh' -type f | wc -l | tr -d ' ')" \
  "$(nse_pg_judge_files "$ROOT" | grep -c '^lib/pg-' || true)"
# ADDING a judge file to the candidate must move the identity too, or a
# candidate could bring its own and keep a matching hash.
mkreal "$TMP/real-added"
printf '# an extra judge file the candidate brought along\n' > "$TMP/real-added/lib/pg-extra.sh"
RG3=$TMP/real-gate-added.json
( nse_pg_gate "$TMP/real-base" "$TMP/real-added" "$RG3" base head \
    "$ROOT/tests/pg-fixtures/facts-seed.json" "$ROOT/tests/pg-fixtures/facts-seed.json" ) \
  >/dev/null 2>&1 || true
assert_eq "p43.4b ADDING a lib/pg-*.sh is a JUDGE_MISMATCH, not an invisible extra" \
  '["JUDGE_MISMATCH"]' "$(jq -c .rejectedBy "$RG3")"
assert_eq "p43.4c and the added file is named, as ABSENT on the trusted side" \
  "lib/pg-extra.sh" \
  "$(jq -r '.findings[] | select(.id=="JUDGE_MISMATCH") | .differingFiles[].path' "$RG3")"
# Change ONE byte of one real judge file and the identity must move.
printf '\n# a candidate edit\n' >> "$TMP/real-head/lib/pg-policy.sh"
RG2=$TMP/real-gate-edited.json
( nse_pg_gate "$TMP/real-base" "$TMP/real-head" "$RG2" base head \
    "$ROOT/tests/pg-fixtures/facts-seed.json" "$ROOT/tests/pg-fixtures/facts-seed.json" ) \
  >/dev/null 2>&1 || true
assert_eq "p43.5 one edited byte in a real judge file is JUDGE_MISMATCH" \
  '["JUDGE_MISMATCH"]' "$(jq -c .rejectedBy "$RG2")"
assert_eq "p43.6 and the report names the file that changed" "lib/pg-policy.sh" \
  "$(jq -r '.findings[] | select(.id=="JUDGE_MISMATCH") | .differingFiles[].path' "$RG2")"
# The facts paths are recorded, so a reader can tell which graph was judged.
assert_ne "p43.7 the report records which facts documents were read" "" \
  "$(jq -r '.roots.headFacts' "$RG")"

head_ "p42  the documentation does not out-claim the evidence"
# The closed line wrote this rule into its own units after finding a correct
# disclosure sitting on screen four, below three sections a reader stops
# before. Position is part of a disclosure; a caveat nobody reaches is not a
# caveat. The same guard, for this line's own documents.
PGDOC=$ROOT/experiments/policy-governed/README.md
assert_ne "p42.1 the README exists" "0" "$(test -f "$PGDOC" && echo 1 || echo 0)"
assert_ne "p42.2 it carries the non-claim about GitHub judge independence" "0" \
  "$(grep -c 'NO CLAIM' "$PGDOC" || true)"
assert_ne "p42.3 naming judge independence" "0" \
  "$(grep -ci 'judge independence' "$PGDOC" || true)"
assert_ne "p42.4 and durable promotion" "0" \
  "$(grep -ci 'durable promotion is solved' "$PGDOC" || true)"
# The pre-registration must carry them too, and its amendments log must exist.
PGPRE=$ROOT/experiments/policy-governed/PREREG.md
assert_ne "p42.5 the pre-registration carries both non-claims" "0" \
  "$(grep -c 'NO CLAIM' "$PGPRE" || true)"
assert_ne "p42.6 and has an amendments log, because a silent amendment is not allowed" "0" \
  "$(grep -c '^## 22. Amendments' "$PGPRE" || true)"
# A claim this line does NOT support must not appear as an assertion anywhere
# in its documents. A sentence may deny it; none may make it.
for banned in 'proves GitHub-level' 'solves durable promotion' 'production-ready'; do
  assert_eq "p42.7 no document asserts '$banned'" "" \
    "$(grep -rn "$banned" "$PGDOC" "$PGPRE" || true)"
done
assert_ne "p42.7a positive control: such a sentence WOULD be caught" "0" \
  "$(printf '%s\n' 'this proves GitHub-level authority' | grep -c 'proves GitHub-level' || true)"
# The run index must not claim a status it has no run for.
PGRUNS=$ROOT/experiments/policy-governed/runs.json
assert_eq "p42.8 the run index is valid JSON" "ok" \
  "$(jq -e . "$PGRUNS" >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "p42.9 every claim marked MEASURED names the run that measured it" "" \
  "$(jq -r '[.primaryClaims[] | select(.status | startswith("MEASURED")) | select(has("evidence") | not) | .id] | join(",")' "$PGRUNS")"
assert_eq "p42.10 every indexed run names the commit it measured" "" \
  "$(jq -r '[.runs[] | select((.measuredCommit // "") | test("^[0-9a-f]{40}$") | not) | (.run|tostring)] | join(",")' "$PGRUNS")"
assert_eq "p42.11 and its verdict and observed trace, not just an expectation" "" \
  "$(jq -r '[.runs[] | select((has("observedTrace") and has("verdict")) | not) | (.run|tostring)] | join(",")' "$PGRUNS")"
# The closed line's index is NOT this line's index, and nothing was appended.
# `tostring` FIRST: some entries carry a .note that is an array, and test() on
# an array is a jq error rather than a false. Through jqx, so an error is a
# visible CHECKER_ERROR instead of an empty string that compares equal to the
# expected empty string and passes.
assert_eq "p42.12 the closed line's run index has not gained entries from this line" "0" \
  "$(jqx -r '[.runs[] | (.note // "") | tostring | select(test("policy-governed"))] | length' "$ROOT/evidence-runs.json")"
assert_eq "p42.12a and the guard did not error while deciding that" "" "$JQ_ERR"
assert_ne "p42.12b positive control: jqx surfaces an error instead of an empty answer" "0" \
  "$(jqx -r '.runs[] | .note | test("x")' "$ROOT/evidence-runs.json" | grep -c CHECKER_ERROR || true)"
# ---------------------------------------------------------------------------
# INDEX PROVENANCE. Both of these were found by a reviewer reading runs.json,
# not by a check -- which is the same closure-bookkeeping class this repository
# has been bitten by before ("(this commit)" as a literal, a stale canonical
# block). The repair comes with the guard.
# ---------------------------------------------------------------------------
# (a) An indexed run that claims to have measured on N Nix versions must carry
#     an artifact for each of them. Runs 4 and 5 recorded only the 2.34.7 leg
#     while both matrix legs had succeeded and both artifacts existed, so the
#     index under-recorded its own provenance on half of each run.
# shellcheck disable=SC2016  # a jq program, handed to the jqx wrapper
assert_eq "p42.14 every indexed run records an artifact for EVERY Nix version it measured on" "" \
  "$(jqx -r '[ .runs[]
               | . as $r
               | .nixVersions[]
               | . as $v
               | select([ $r.artifacts // {} | keys[] | select(contains($v)) ] | length == 0)
               | "run \($r.run) has no artifact for nix \($v)" ] | join("; ")' \
       "$PGRUNS")"
assert_eq "p42.14a and the guard did not error while deciding that" "" "$JQ_ERR"
# The red control, because "no run is missing an artifact" is also what this
# says about an index with no runs in it.
assert_ne "p42.14b positive control: a missing leg IS caught" "0" \
  "$(jq -n '{runs:[{run:9,nixVersions:["2.34.7","2.24.9"],
                    artifacts:{"q-nix2.34.7":1}}]}' \
     | jq -r '[ .runs[] | . as $r | .nixVersions[] | . as $v
                | select([ $r.artifacts // {} | keys[] | select(contains($v)) ] | length == 0)
                | "x" ] | length')"
# (b) A prose reference to "run N" inside an indexed run must name an INDEXED
#     run. PREREG.md §19: a GitHub Actions workflow number is not a number of
#     knowledge. Run 4's notMeasured said "Run 10's step", which is a workflow
#     number wearing the word `run` in the one namespace where that word is
#     already taken.
# shellcheck disable=SC2016  # a jq program, handed to the jqx wrapper
assert_eq "p42.15 no prose names a 'run N' that is not an indexed run" "" \
  "$(jqx -r '[ .runs[].run ] as $known
              | [ .runs[]
                  | .run as $r
                  | ((.findings // []) + (.defectsFoundInThisRun // [])
                     + (.notMeasured // []) + [ .supports // "", .verdict // "" ])[]
                  | [ match("[Rr]un ([0-9]+)"; "g").captures[0].string | tonumber ]
                  | .[]
                  # `. as $n` FIRST. `$known | index(.)` rebinds . to the
                  # ARRAY, so index() looks for the array inside itself, finds
                  # it at 0, and the select is never true -- the guard was
                  # INERT and passed by never selecting anything. Its positive
                  # control caught that on the first run, which is the entire
                  # reason a guard ships with one.
                  | . as $n
                  | select(($known | index($n)) == null)
                  | "run \($r) prose names run \($n), which is not indexed" ]
              | unique | join("; ")' "$PGRUNS")"
assert_eq "p42.15a and that guard did not error either" "" "$JQ_ERR"
assert_ne "p42.15b positive control: a workflow number in prose IS caught" "0" \
  "$(jq -n '{runs:[{run:1,findings:["Run 10 step produced a green"]}]}' \
     | jq -r '[ .runs[].run ] as $known
               | [ .runs[] | (.findings // [])[]
                   | [ match("[Rr]un ([0-9]+)"; "g").captures[0].string | tonumber ] | .[]
                   | . as $n | select(($known | index($n)) == null) ] | length')"
assert_eq "p42.15c and a reference to a REAL indexed run is not caught" "0" \
  "$(jq -n '{runs:[{run:1,findings:["as run 1 showed"]},{run:2,findings:[]}]}' \
     | jq -r '[ .runs[].run ] as $known
               | [ .runs[] | (.findings // [])[]
                   | [ match("[Rr]un ([0-9]+)"; "g").captures[0].string | tonumber ] | .[]
                   | . as $n | select(($known | index($n)) == null) ] | length')"

assert_ne "p42.13 and this line's index names the frozen commit it branched from" "0" \
  "$(jq -r '.branchedFrom.commit | test("^84354e85") | if . then 1 else 0 end' "$PGRUNS")"

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
  # THE DELTA THAT HAS ACTUALLY BITTEN.
  #
  # Three shellchecks run against this tree and they are not the same version:
  # the one installed here, the one on the GitHub runner, and the one nixpkgs
  # pins for `nix flake check`. Twice now the runner has reported a class the
  # local one does not emit by default -- SC2015, then SC2120/SC2119 -- and
  # both times the first notice was a red CI job.
  #
  # So the local mirror explicitly INCLUDES the classes that have bitten. Not
  # --enable=all, which buries them under two thousand style findings nobody
  # will read; the specific ones, growable by one line the next time a version
  # difference costs a cycle.
  sc_delta=$(cd "$ROOT" && shellcheck -x -e SC1091 --shell=bash \
               --include=SC2015,SC2119,SC2120,SC2310,SC1009,SC1072,SC1073 \
               bin/nse-pg lib/pg-*.sh tests/pg-unit.sh 2>&1) && scd_rc=0 || scd_rc=$?
  assert_eq "p10.3a and clean on the classes other shellcheck versions enable" "0" "$scd_rc"
  [ "$scd_rc" -eq 0 ] || printf '%s\n' "$sc_delta" | head -30
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
