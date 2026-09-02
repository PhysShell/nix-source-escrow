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
nse_to_sri() {
  local h=$1 algo=${2:-sha256}
  case $h in
    *-*) # already SRI (algo-base64)
      printf '%s\n' "$h" ;;
    *:*) # <algo>:<hash> or fixed:r:<algo>:<hash>
      local a=${h##*:} ; local rest=${h%:*} ; local alg=${rest##*:}
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
nse_nix() {
  NIX_CONFIG="experimental-features = nix-command flakes
warn-dirty = false
${NSE_EXTRA_NIX_CONFIG:-}" nix "$@"
}
