# shellcheck shell=bash
#
# policy-governed line -- FACTS.
#
# The first of the four layers PREREG.md §6 keeps apart:
#
#     FACTS      what discovery observed          <- this file
#     POLICY     what the project declared
#     DECISION   what the trusted judge concluded
#     EVIDENCE   what actually happened
#
# A fact here is never a bare value. It is a value AND how it was obtained,
# because the difference between "the derivation states owner = NixOS" and "we
# parsed NixOS out of a URL" is the difference between a fact and a guess with
# good manners. The closed line already paid for this lesson once, in a
# function that defaulted a bare digest to sha256 because the algorithm had not
# been recorded.

# ---------------------------------------------------------------------------
# The fact reader, as a jq program.
#
# It is a jq program and not shell because it has to be testable against BOTH
# derivation-document schemas without a Nix in sight. The closed line measured
# those two shapes the expensive way -- the same tool on the same flake saw 165
# fixed-output sources on one Nix version and 0 on the other -- so a fact
# reader that has only ever been run against one of them is a fact reader with
# a 50% chance.
#
# Prepend NSE_JQ_DRV_ATTRS before this; it supplies nse_attr / nse_urls_of /
# nse_structured_attrs, which already know about `env.__json`.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016,SC2034  # a jq program; consumed by the drivers below
NSE_PG_JQ_FACTS='
# PRESENCE, via has() and never via `// null`.
#
# `stripRoot = false` is the whole reason. Read with `//`, a stated false comes
# back indistinguishable from an absent attribute, and the fact whose entire
# job is to record that the root was NOT stripped reports UNKNOWN. DESIGN.md
# §307 warned about exactly this field, in exactly these words, and it is worth
# a function rather than a convention.
def nse_pg_has($d; $k):
  (nse_structured_attrs($d)) as $s | (($d.env // {})) as $e
  | (($s | has($k)) or ($e | has($k)));

# WHERE the attribute was found. Three sites, not two, and the third one is
# the whole reason this function exists:
#
#   structuredAttrs   2.34.7 carries the attributes of a __structuredAttrs
#                     derivation in a real JSON object under this key
#   env.__json        2.24.9 carries THE SAME attributes as a STRING of JSON
#                     under env.__json
#   env               a plain, unstructured derivation attribute
#
# nse_structured_attrs() deliberately hides that difference so callers get the
# same values from both versions -- which is right for the VALUE and wrong for
# the PROVENANCE. Reported through it alone, a fact read out of env.__json on
# 2.24.9 claimed to have come from `structuredAttrs`, a key that document does
# not contain. A provenance that names a place the document has not got is not
# a provenance, and re-measuring from it lands nowhere.
def nse_pg_attr_site($d; $k):
  if (($d | has("structuredAttrs")) and ($d.structuredAttrs != null)
      and ($d.structuredAttrs | has($k)))
    then "structuredAttrs"
  elif ((($d.env // {}) | has("__json")) and ((nse_structured_attrs($d)) | has($k)))
    then "env.__json"
  elif (($d.env // {}) | has($k))
    then "env"
  else null end;

# The three permitted provenance values, and nothing else. PREREG.md §4.1.
#
#   DERIVATION_ATTR   read straight out of a derivation attribute
#   URL_FALLBACK      parsed from a URL, and SAYING SO
#   UNKNOWN           absent, and no permitted fallback applies
#
# There is no fourth value meaning "probably". An absent attribute yields
# UNKNOWN; it does not yield a guess.
def nse_pg_fact($d; $k):
  if nse_pg_has($d; $k)
  then { value: (nse_attr($d; $k)), source: "DERIVATION_ATTR",
         attrKey: $k, attrSite: (nse_pg_attr_site($d; $k)) }
  else { value: null, source: "UNKNOWN", attrKey: null, attrSite: null }
  end;

def nse_pg_host($u):
  if ($u | type) != "string" then null
  elif ($u | test("^[a-zA-Z][a-zA-Z0-9+.-]*://")) then
    ($u | sub("^[^:]+://"; "") | sub("/.*$"; "") | sub("^[^@]*@"; "") | sub(":[0-9]+$"; ""))
  else null end;

# originHost is the ONLY fact with a permitted URL fallback, and it is marked
# URL_FALLBACK when it takes it. PREREG.md §4.1.
def nse_pg_origin_host($d):
  (nse_pg_fact($d; "originHost")) as $direct
  | if $direct.source == "DERIVATION_ATTR" then $direct
    else (nse_urls_of($d)) as $urls
      | ( [ $urls[] | nse_pg_host(.) ] | map(select(. != null)) | unique ) as $hosts
      | if ($hosts | length) == 1
        then { value: $hosts[0], source: "URL_FALLBACK", attrKey: "url", attrSite: "url" }
        # Zero hosts is nothing to fall back to. MORE THAN ONE is worse than
        # nothing: a source with mirrors on two hosts has no single origin
        # host, and picking the first is picking whichever the fetcher listed
        # first. Both are UNKNOWN, and the count is kept so the two are
        # distinguishable afterwards.
        else { value: null, source: "UNKNOWN", attrKey: null, attrSite: null,
               urlHostCount: ($hosts | length) }
        end
    end;

# The seven facts PREREG.md §4 registers, plus the origin host.
#
# `rev` is in this list and has NO fallback branch anywhere in this file. It is
# never synthesised from a URL. A URL that ends in a forty-character hex string
# is a URL that ends in a forty-character hex string.
def nse_pg_github_facts($d):
  {
    owner:      nse_pg_fact($d; "owner"),
    repo:       nse_pg_fact($d; "repo"),
    rev:        nse_pg_fact($d; "rev"),
    tag:        nse_pg_fact($d; "tag"),
    githubBase: nse_pg_fact($d; "githubBase"),
    stripRoot:  nse_pg_fact($d; "stripRoot"),
    extension:  nse_pg_fact($d; "extension"),
    originHost: nse_pg_origin_host($d)
  };

# Every attribute name the document carries for this derivation.
#
# Count to detect, NAME to diagnose (EXPERIMENT-PROTOCOL.md §1). Three runs of
# counting anomalies settled nothing in the closed line; one run that named
# them settled it in the first line. So the probe reports the key set, not the
# key count, and a reader who disagrees with a verdict below can see the
# document the verdict was drawn from.
#
# `__json` is EXCLUDED. It is not an attribute of the derivation; it is the
# envelope 2.24.9 packs the attributes into, and it appears in exactly one of
# the two documents Nix produces for one derivation. Left in, the key set of a
# fixed-output source differs between Nix versions for a reason that is purely
# representational -- which is the precise shape of the defect that had this
# repository reporting 165 sources on one version and 0 on the other.
def nse_pg_attr_keys($d):
  ((nse_structured_attrs($d) | keys) + (($d.env // {}) | keys))
  | map(select(. != "__json")) | unique;
'

# The jq preamble every driver in this line uses.
nse_pg_jq_prelude() { printf '%s\n%s\n' "$NSE_JQ_DRV_ATTRS" "$NSE_PG_JQ_FACTS"; }

# ---------------------------------------------------------------------------
# nse_pg_facts_of <normalised-drv-map.json> <drv-name>
#
# stdout: the fact object for one derivation.
# Exit non-zero, with nothing on stdout, if that derivation is not in the map.
#
# NOT `// {}`. A derivation this document does not contain is a read failure,
# not a derivation with no attributes -- the standing rule of this repository,
# and the one that turned an unreadable graph into a green run about nothing.
# ---------------------------------------------------------------------------
nse_pg_facts_of() {
  local map=$1 drv=$2
  local key=${drv##*/}
  jq -e --arg k "$key" "$(nse_pg_jq_prelude)"'
    if has($k) | not
    then error("derivation \($k) is not in this document. That is a read failure, not an empty derivation.")
    else .[$k] as $d
      | { drv: $k,
          name: (if ($d|has("name")) then $d.name else null end),
          facts: nse_pg_github_facts($d),
          attrKeys: nse_pg_attr_keys($d) }
    end' "$map"
}
