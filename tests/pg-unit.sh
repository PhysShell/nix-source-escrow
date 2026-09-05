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
