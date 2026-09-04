# shellcheck shell=bash
# Shared helpers for nix-source-escrow.
# Sourced by bin/nix-source-escrow; not executable on its own.

nse_die() { printf 'nix-source-escrow: error: %s\n' "$*" >&2; exit 1; }
nse_warn() { printf 'nix-source-escrow: warning: %s\n' "$*" >&2; }
nse_log() { printf '==> %s\n' "$*" >&2; }
nse_step() { printf '\n=== %s ===\n' "$*" >&2; }

nse_require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 \
      || nse_die "required command '$c' not found on PATH. Run inside 'nix develop' in this repository."
  done
}

# Absolute path of a directory that may not exist yet.
nse_abspath() {
  local p=$1
  case $p in
    /*) printf '%s\n' "$p" ;;
    *)  printf '%s\n' "$PWD/$p" ;;
  esac
}

# The Nix store directory (usually /nix/store). Derived, never hardcoded.
# Cached: every caller needs it and it cannot change mid-run. Resolved via
# builtins.storeDir because `nix config show` has no `store-dir` option.
NSE_STORE_DIR_CACHE=""
nse_store_dir() {
  if [ -z "$NSE_STORE_DIR_CACHE" ]; then
    NSE_STORE_DIR_CACHE=$(nix eval --impure --raw --expr 'builtins.storeDir' 2>/dev/null) \
      || nse_die "cannot determine builtins.storeDir from nix"
    case $NSE_STORE_DIR_CACHE in
      /*) : ;;
      *)  nse_die "builtins.storeDir returned '$NSE_STORE_DIR_CACHE', which is not an absolute path" ;;
    esac
  fi
  printf '%s\n' "$NSE_STORE_DIR_CACHE"
}

# Split an installable "<flakeref>#<attr>" into its flake reference.
# `.#foo` -> `.`, `path:/x/y#foo` -> `path:/x/y`, `path:/x/y` -> `path:/x/y`.
nse_flakeref_of() {
  local inst=$1
  printf '%s\n' "${inst%%#*}"
}

# Normalise a hash to SRI form so hashes from different Nix APIs compare equal.
# Inputs seen in the wild, all of which must land on the same string:
#   sha256-<base64>            SRI, from a derivation's outputHash
#   fixed:r:sha256:<base32>    a narinfo CA field
#   fixed:r:sha256-<base64>    the same field as newer Nix renders it in JSON
# The content-address prefix is stripped first, so the algo/hash split below
# never has to guess which colon it is looking at.
nse_to_sri() {
  local h=$1 algo=${2:-sha256}
  h=${h#fixed:}; h=${h#text:}; h=${h#r:}
  case $h in
    *-*) # already SRI (algo-base64)
      printf '%s\n' "$h" ;;
    *:*) # <algo>:<hash>
      local a=${h##*:} ; local alg=${h%%:*}
      nix hash convert --hash-algo "$alg" --to sri "$a" ;;
    *)
      nix hash convert --hash-algo "$algo" --to sri "$h" ;;
  esac
}


# Hosts we treat as "dependency origins" for reporting purposes. The acceptance
# test blocks *all* egress, so this list only classifies; it never gates.
# shellcheck disable=SC2034  # consumed by lib/discover.sh
NSE_ORIGIN_HOSTS_DEFAULT="github.com codeload.github.com raw.githubusercontent.com objects.githubusercontent.com gitlab.com bitbucket.org codeberg.org git.sr.ht gitea.com"

# Deterministic JSON: sort object keys so the manifest does not churn.
nse_json_canonical() { jq -S '.'; }

# Write $2 to $1 atomically (never leave a half-written manifest behind).
nse_write_file() {
  local dest=$1 tmp
  tmp="$(mktemp "${dest}.XXXXXX")" || nse_die "mktemp failed for $dest"
  cat > "$tmp" || { rm -f "$tmp"; nse_die "failed writing $dest"; }
  chmod 0644 "$tmp" || { rm -f "$tmp"; nse_die "failed setting mode on $dest"; }
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; nse_die "failed installing $dest"; }
}

# `nix` invocation used for everything the tool does on the *host* store.
# Keeps our behaviour independent of the user's ambient nix.conf where it
# matters, and makes every option we rely on visible in this one place.
# NSE_EXTRA_NIX_CONFIG is the escape hatch for backend credentials
# (netrc-file, access-tokens, aws-* settings) that a non-file:// escrow needs.
nse_nix() {
  NIX_CONFIG="experimental-features = nix-command flakes
warn-dirty = false
${NSE_EXTRA_NIX_CONFIG:-}" nix "$@"
}

# ---------------------------------------------------------------------------
# Escrow backend URLs
#
# PRESERVE writes to NSE_STORE_URL. VERIFY and PROVE read from
# NSE_SUBSTITUTER_URL. They are two settings and not one because once the
# escrow stops being a directory on your laptop, "the store I push to" and
# "the substituter a consumer configures" stop being the same string --
# an Attic/S3/Artifactory cache is written and read through different
# credentials, and often through different URLs.
#
# Both default to the local file:// cache, so the v0.1 behaviour is unchanged
# unless you ask for something else.
# ---------------------------------------------------------------------------

nse_url_scheme() {
  case $1 in
    *://*) printf '%s\n' "${1%%://*}" ;;
    /*)    printf 'file\n' ;;
    *)     printf 'unknown\n' ;;
  esac
}

nse_url_is_file() { [ "$(nse_url_scheme "$1")" = file ]; }

# The directory behind a file:// URL, query string stripped.
nse_url_file_path() {
  local u=$1
  u=${u#file://}
  printf '%s\n' "${u%%\?*}"
}

nse_url_strip_query() { printf '%s\n' "${1%%\?*}"; }

# What kind of thing is on the other end. Recorded in the manifest so the
# evidence says which backend actually held the objects.
nse_backend_name() {
  case $(nse_url_scheme "$1") in
    file)        printf 'local-file-binary-cache\n' ;;
    s3)          printf 's3-binary-cache\n' ;;
    http|https)  printf 'http-binary-cache\n' ;;
    ssh|ssh-ng)  printf 'remote-nix-store\n' ;;
    daemon|unix) printf 'nix-daemon-store\n' ;;
    *)           printf 'nix-store\n' ;;
  esac
}

# Default write URL for the built-in local backend.
nse_default_store_url() {
  case $NSE_CACHE in
    *[!A-Za-z0-9._/-]*)
      nse_die "escrow cache path contains characters that are unsafe in a file:// URL: '$NSE_CACHE'
       Use --escrow-dir to pick a path matching [A-Za-z0-9._/-]+ , or pass
       --escrow-store with a URL of your own." ;;
  esac
  printf 'file://%s?compression=%s\n' "$NSE_CACHE" "${NSE_COMPRESSION:-zstd}"
}

# ---------------------------------------------------------------------------
# Batched store operations
#
# One `nix` process per store path is the wrong shape twice over: on a 30k-path
# closure it is 30k process startups, and passing the same list on one command
# line eventually hits ARG_MAX ("Argument list too long"). Everything that
# takes a path list goes through here instead.
# ---------------------------------------------------------------------------

NSE_BATCH_SIZE=${NSE_BATCH_SIZE:-256}

# nse_nix_batched <paths-file> <nix args...>  ->  runs `nix <args> <chunk...>`
nse_nix_batched() {
  local file=$1; shift
  local -a chunk
  local fd rc=0
  exec {fd}<"$file" || return 1
  while mapfile -t -u "$fd" -n "$NSE_BATCH_SIZE" chunk && [ "${#chunk[@]}" -gt 0 ]; do
    if ! nse_nix "$@" "${chunk[@]}"; then rc=1; break; fi
  done
  exec {fd}<&-
  return "$rc"
}

# stdin: store paths.  stdout: the subset the given store actually holds.
# Never one process per path.
nse_store_present() {
  local url=$1
  if nse_url_is_file "$url"; then
    # A file:// binary cache is a directory of <hashpart>.narinfo. Presence is
    # a stat, not a process.
    local dir p hp
    dir=$(nse_url_file_path "$url")
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      hp=${p##*/}; hp=${hp%%-*}
      if [ -f "$dir/$hp.narinfo" ]; then printf '%s\n' "$p"; fi
    done
    return 0
  fi
  # Backend-neutral: ask Nix, in batches.
  #
  # THE DEFECT THIS REPLACES. `nix path-info --json` does not omit a path it
  # cannot find and does not fail the command: it emits `"<path>": null` and
  # exits 0. Both measured Nix versions (2.24.9 and 2.34.7) do this. The old
  # parser took `keys[]`, so every path we ASKED about came back as present:
  #
  #     ABSENT -> "path": null -> keys[] -> PRESENT
  #
  # 227 candidates went in and 227 "supplied" came out, including a store path
  # this machine had built ten minutes earlier that no public cache could
  # possibly hold. `nix copy` then tried to fetch it and the whole run died.
  #
  # This is the same family as every other defect here -- structural presence
  # mistaken for semantic presence -- and it made remote-backend presence
  # unsound everywhere, not only for the binary tier. The file:// path was
  # never affected: it stats a narinfo.
  #
  # An unrecognised response shape is fatal, not empty.
  local -a chunk
  local pathinfo_json p
  while mapfile -t -n "$NSE_BATCH_SIZE" chunk && [ "${#chunk[@]}" -gt 0 ]; do
    if pathinfo_json=$(nse_nix path-info --store "$url" --json "${chunk[@]}" 2>/dev/null); then
      printf '%s\n' "$pathinfo_json" | nse_pathinfo_present_keys || return 1
    else
      # A batch can still fail outright (a malformed object, a transport
      # error). Ask per path, and let each answer stand on its own.
      for p in "${chunk[@]}"; do
        if pathinfo_json=$(nse_nix path-info --store "$url" --json "$p" 2>/dev/null); then
          printf '%s\n' "$pathinfo_json" | nse_pathinfo_present_keys || return 1
        fi
      done
    fi
  done
  return 0
}

# stdin: a `nix path-info --json` document. stdout: the paths it says EXIST.
#
# `null` is the answer for "I do not have this", and it is the whole point of
# this function. An unrecognised shape exits non-zero rather than yielding
# nothing, because "I cannot read this" is not "there is nothing here".
nse_pathinfo_present_keys() {
  jq -r '
    if   type == "object" then (to_entries[] | select(.value != null) | .key)
    elif type == "array"  then (.[] | select(. != null and (.path? != null)) | .path)
    else error("unrecognised `nix path-info --json` response shape: \(type)")
    end'
}

# Path metadata for a whole set, as JSONL -- one object per line:
#     {"path": "...", "ca": "..." | "", "sigs": N}
#
# It used to be TSV, and that cost a real defect. A signed object has an EMPTY
# ca field, so its line is `path<TAB><TAB>1`; `read -r p ca sigs` with
# IFS=$'\t' COLLAPSES the two tabs, because tab is IFS whitespace. Every signed
# and unsigned object was then misclassified as content-addressed, the trust
# probe found no sample of either class and reported "skipped" -- while the
# composition counter in the same report, which used `awk -F'\t'`, printed the
# correct 53 and 1. Two readers of one file, one of them silently wrong.
#
# JSON has exactly one answer to "what is an empty field", so it is used here.
# The awk output is still tab-separated internally, but jq -R + split("\t")
# parses it -- jq's split does not collapse separators.
#
# For a file:// cache the narinfos are read directly, in ONE awk process. That
# is deliberate and not just a speed choice: `nix path-info` refuses a batch
# outright if a single object in it is malformed, and surviving a deliberately
# corrupted escrow (test t06) is a requirement.
nse_store_meta() {
  local url=$1
  if nse_url_is_file "$url"; then
    local dir; dir=$(nse_url_file_path "$url")
    awk -v dir="$dir" '
      NF {
        n = split($0, a, "/"); hp = a[n]; sub(/-.*$/, "", hp)
        f = dir "/" hp ".narinfo"
        ca = ""; sigs = 0
        while ((getline line < f) > 0) {
          if (line ~ /^CA: /)       { ca = substr(line, 5) }
          else if (line ~ /^Sig: /) { sigs++ }
        }
        close(f)
        printf "%s\t%s\t%d\n", $0, ca, sigs
      }' \
      | jq -R -c 'split("\t") | {path: .[0], ca: (.[1] // ""), sigs: ((.[2] // "0") | tonumber)}'
    return 0
  fi
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/nse-meta.XXXXXX") || return 1
  cat > "$tmp"
  nse_store_pathinfo "$url" "$tmp" \
    | jq -c 'to_entries[] | {path: .key, ca: (.value.ca // ""),
                             sigs: ((.value.signatures // []) | length)}'
  rm -f "$tmp"
  return 0
}

# Classify one metadata record. The single definition both VERIFY and TRUST
# use, so they cannot disagree about what "signed" means again.
# shellcheck disable=SC2034  # consumed by lib/verify.sh and lib/trust.sh
NSE_JQ_CLASSIFY='def nse_class:
  if   ((.ca // "") | startswith("text:")) then "ca-text"
  elif ((.ca // "") != "")                 then "ca-fixed"
  elif ((.sigs // 0) > 0)                  then "signed"
  else                                          "unsigned" end;'

# Path metadata for a whole set, as one JSON object keyed by store path.
# Batched, and backend-neutral: the same call answers "is it content-addressed"
# and "is it signed" for a file:// directory, an S3 bucket and an Attic server.
# Ask it only about paths already known to be present -- a batch containing one
# absent path fails as a whole.
nse_store_pathinfo() {
  local url=$1 file=$2
  local -a chunk
  local fd pathinfo_json           # not `out`: see nse_store_present
  exec {fd}<"$file" || return 1
  {
    while mapfile -t -u "$fd" -n "$NSE_BATCH_SIZE" chunk && [ "${#chunk[@]}" -gt 0 ]; do
      if pathinfo_json=$(nse_nix path-info --store "$url" --json "${chunk[@]}" 2>/dev/null); then
        printf '%s\n' "$pathinfo_json" \
          | jq 'if type=="array" then (map(select(.path? != null)) | map({key:.path, value:.}) | from_entries)
                else with_entries(select(.value != null)) end'
      else
        # One malformed or absent object fails the whole batch, so fall back
        # to asking per path -- for that batch only.
        local p
        for p in "${chunk[@]}"; do
          if pathinfo_json=$(nse_nix path-info --store "$url" --json "$p" 2>/dev/null); then
            printf '%s\n' "$pathinfo_json" \
              | jq 'if type=="array" then (map(select(.path? != null)) | map({key:.path, value:.}) | from_entries)
                    else with_entries(select(.value != null)) end'
          fi
        done
      fi
    done
  } | jq -s 'add // {}'
  exec {fd}<&-
  return 0
}

# ---------------------------------------------------------------------------
# Provenance: bind a piece of evidence to the code and inputs that produced it
#
# "E1 = CONFIRMED" is worth nothing two commits later if nothing records which
# commit it was confirmed on, or whether the tree was dirty at the time.
# ---------------------------------------------------------------------------

NSE_NIX_VERSION_CACHE=""
nse_nix_version() {
  if [ -z "$NSE_NIX_VERSION_CACHE" ]; then
    NSE_NIX_VERSION_CACHE=$(nix --version 2>/dev/null) || NSE_NIX_VERSION_CACHE="unknown"
  fi
  printf '%s\n' "$NSE_NIX_VERSION_CACHE"
}

nse_sha256_of() {
  if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else printf '\n'; fi
}

# Where the revision comes from, in order of authority:
#
#   flake       $out/share/nix-source-escrow/build-info.json, stamped in at
#               build time. An installed /nix/store tree has no .git (the src
#               filter drops it) and no working tree to be dirty, so asking git
#               at runtime there returns nothing however many git binaries are
#               on PATH -- which is what an earlier version of this function
#               did, and it would have reported `null` for every packaged run.
#   git         a dev checkout: HEAD plus whether the tree is dirty. Untracked
#               files count as dirty -- a stray lib/*.sh that `nix flake check`
#               never saw is exactly what makes a result unreproducible.
#   unknown     neither. Said out loud rather than guessed.
nse_provenance() {
  local root=${NSE_ROOT:-$PWD}
  local info=$root/share/nix-source-escrow/build-info.json
  local rev="" dirty=null source=unknown

  if [ -f "$info" ]; then
    rev=$(jq -r '.toolRevision // ""' "$info")
    # `//` treats false as absent, so a clean packaged build would come back
    # `null` instead of `false`. DESIGN.md §6 warns about exactly this operator
    # and this function still walked into it.
    dirty=$(jq -c 'if has("workingTreeDirty") then .workingTreeDirty else null end' "$info")
    source=$(jq -r '.revisionSource // "flake"' "$info")
  elif command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    rev=$(git -C "$root" rev-parse HEAD 2>/dev/null) || rev=""
    if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then dirty=true; else dirty=false; fi
    source=git-checkout
  fi
  if [ -z "$rev" ] || [ "$rev" = unknown ]; then
    rev=""
    if [ "$source" != unknown ]; then source="$source-no-revision"; fi
  fi

  jq -n \
    --arg rev "$rev" \
    --argjson dirty "$dirty" \
    --arg source "$source" \
    --arg nixVersion "$(nse_nix_version)" \
    --arg manifest "$(nse_sha256_of "${NSE_DIR:-/nonexistent}/manifest.json")" \
    --arg closure  "$(nse_sha256_of "${NSE_DIR:-/nonexistent}/closure.json")" \
    '{toolRevision:   (if $rev == "" then null else $rev end),
      revisionSource: $source,
      workingTreeDirty: $dirty,
      nixVersion:     $nixVersion,
      manifestSha256: (if $manifest == "" then null else $manifest end),
      closureSha256:  (if $closure  == "" then null else $closure  end)}'
}

# stdout: every store path a file:// binary cache actually holds.
# Used to measure a proof replica rather than assume its contents: `nix copy`
# copies CLOSURES, so asking for N roots does not mean N objects arrive.
nse_store_list() {
  local url=$1
  nse_url_is_file "$url" || return 0
  local dir; dir=$(nse_url_file_path "$url")
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.narinfo' -print0 2>/dev/null \
    | xargs -0 -r sed -n 's/^StorePath: //p' 2>/dev/null || :
  return 0
}

# ---------------------------------------------------------------------------
# Fail-closed reading
#
# The rule this project learned the hard way, stated once:
#
#     MISSING / UNPARSEABLE / UNKNOWN_SCHEMA  is not  EMPTY
#
# Three separate defects in this tool were the same mistake: `.derivations //
# {}` turned an unreadable document into an empty graph, `.workingTreeDirty //
# null` turned a clean tree into an unknown one, and a collapsed tab turned an
# empty field into the next column. Each produced a green result about nothing.
# Where a value is expected non-empty by construction, observing zero is a read
# failure until proven otherwise.
# ---------------------------------------------------------------------------

# Which shape of `nix derivation show` is this document?
# Echoes: envelope | flat-map | unknown   (never guesses, never defaults)
nse_drv_schema() {
  local f=$1
  [ -s "$f" ] || { printf 'unknown\n'; return 0; }
  if jq -e 'type == "object" and has("derivations")' "$f" >/dev/null 2>&1; then
    printf 'envelope\n'
  elif jq -e 'type == "object" and length > 0
              and (to_entries | all(.key | endswith(".drv")))
              and (to_entries[0].value | type == "object" and has("outputs"))' \
         "$f" >/dev/null 2>&1; then
    printf 'flat-map\n'
  else
    printf 'unknown\n'
  fi
}

# The derivation map itself, whichever shape it arrived in.
nse_drv_map() {
  local f=$1
  # The two schemas also disagree about the KEY, which was measured only after
  # the schema difference had already been fixed:
  #
  #   2.34.7 envelope : "013mqc5...-expr-strcmp.patch.drv"
  #   2.24.9 flat map : "/nix/store/013mqc5...-expr-strcmp.patch.drv"
  #
  # discover.sh builds drvPath as "$storedir/" + key, so on 2.24.9 every
  # derivation path it recorded was /nix/store//nix/store/... -- a path that
  # exists nowhere. Keys are normalised to the bare object name here, once, so
  # neither caller has to know which Nix produced the document.
  local norm='with_entries(.key |= sub("^.*/"; ""))'
  case $(nse_drv_schema "$f") in
    envelope) jq ".derivations | $norm" "$f" ;;
    flat-map) jq "$norm" "$f" ;;
    *)        return 1 ;;
  esac
}
