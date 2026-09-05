# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2016 disabled file-wide: every single-quoted $ below is a jq program.
#
# policy-governed line -- COMMIT 8, part 2: PR SCRATCH AND ACCEPTANCE.
#
# PREREG.md §14. The pipeline, and the four words that bound it:
#
#     candidate graph -> facts -> trusted base policy -> decisions
#                     -> local ephemeral scratch -> verify -> acceptance
#
#     local.  ephemeral.  credential-free.  candidate untrusted.
#
# NO BYTES PRODUCED BY THE UNTRUSTED CANDIDATE PHASE ARE PROMOTED INTO DURABLE
# STORAGE IN THIS VERSION. Not "should not". The preflight below refuses to run
# if the destination is not local and ephemeral, and refuses if a credential is
# in reach -- because "we did not intend to promote anything" is not a property,
# it is a hope.
#
# The preserve / verify / prove stages are the CLOSED line and are not rewritten
# here. They are invoked. PREREG.md §18 commit 8: reuse them, do not rewrite
# them without need.

# ---------------------------------------------------------------------------
# THE PREFLIGHT
#
# Deliberately pure: paths, URLs and environment names in, findings out. No
# Nix, no store, no network -- so the invariants that bound the untrusted phase
# can be re-tested by anyone, on any machine, in a second.
#
#   nse_pg_scratch_preflight <scratch-dir> <store-url> <guarantee> <env-names...>
# ---------------------------------------------------------------------------
NSE_PG_CREDENTIAL_ENV="NSE_EXTRA_NIX_CONFIG AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE NIX_NETRC_FILE NETRC ATTIC_TOKEN GITHUB_TOKEN GH_TOKEN NIX_ACCESS_TOKENS"

# SCRUB, then check. Not check, then complain.
#
# The first version of this preflight only OBSERVED the environment, and the
# very first machine it ran on had GITHUB_TOKEN, GH_TOKEN and two AWS keys in
# it -- so the honest result was a refusal, on every run, forever. A refusal
# that fires on every run is a refusal that gets deleted.
#
# The right shape is to make the property true rather than to report that it is
# false: unset them here, in this process, before anything of the untrusted
# phase is started, and record BY NAME which were removed. The preflight then
# checks the environment that the phase will actually see, and a credential
# still standing after this is a real finding rather than ambient noise.
#
# THE RESULT COMES BACK IN A GLOBAL, AND THAT IS NOT LAZINESS.
#
# The first version returned the list on stdout, so every caller wrote
#
#     scrubbed=$(nse_pg_scrub_credentials)
#
# and a command substitution is a SUBSHELL. The unsets happened in a child that
# exited immediately, the parent kept every credential, and the function
# cheerfully reported having removed four of them. It printed the right answer
# and did nothing -- which is worse than doing nothing, because the report says
# the property holds.
#
# That is the same shape as the closed line DESIGN.md §19 defect, where a stage
# run inside `$( )` lost `set -e` and a failure became a value. A function whose
# entire purpose is a side effect on this process must not be invoked in a way
# that discards this process.
#
# `unset` here affects the rest of this process on purpose. Nothing downstream
# of a scratch run has any business holding a credential.
NSE_PG_SCRUBBED=""
nse_pg_scrub_credentials() {
  # `var`, not `name`. u14 in the closed line suite forbids localising any name
  # stdenv exports, because `local` does NOT clear an inherited export
  # attribute -- and a large value later assigned to such a local travels in
  # the environment of every child until an exec dies E2BIG. That killed a
  # whole origin-independence run once. The guard caught this file twice.
  local var
  NSE_PG_SCRUBBED=""
  for var in $NSE_PG_CREDENTIAL_ENV; do
    if [ -n "${!var:-}" ]; then
      NSE_PG_SCRUBBED="$NSE_PG_SCRUBBED $var"
      unset "$var"
    fi
  done
  NSE_PG_SCRUBBED=${NSE_PG_SCRUBBED# }
}

nse_pg_scratch_preflight() {
  local scratch=$1 store_url=$2 guarantee=$3
  local set_creds="" var

  # Which credential-shaped variables are actually SET and non-empty. Named,
  # not counted: a run refused for "1 credential present" tells nobody which.
  for var in $NSE_PG_CREDENTIAL_ENV; do
    if [ -n "${!var:-}" ]; then set_creds="$set_creds $var"; fi
  done
  set_creds=${set_creds# }

  # Quoted: bare `file` is the name of a command, and shellcheck is right to
  # ask whether an unquoted one was meant to be run.
  local scheme="file" is_local=true
  case $store_url in
    file://*|/*) scheme="file"; is_local=true ;;
    *://*) scheme=${store_url%%://*}; is_local=false ;;
    *) scheme="unknown"; is_local=false ;;
  esac

  # Is the destination INSIDE the scratch directory? A file:// URL pointing at
  # a durable path is local and still a promotion.
  local store_path=${store_url#file://}; store_path=${store_path%%\?*}
  local inside=false
  case $store_path in
    "$scratch"|"$scratch"/*) inside=true ;;
  esac

  local known_guarantee=false
  case $guarantee in
    escrow-replay|source-origin-independence) known_guarantee=true ;;
  esac

  nse_pg_jq -n \
    --arg scratch "$scratch" --arg storeUrl "$store_url" --arg scheme "$scheme" \
    --arg guarantee "$guarantee" --arg creds "$set_creds" \
    --argjson isLocal "$is_local" --argjson inside "$inside" \
    --argjson knownGuarantee "$known_guarantee" \
    '{ scratchDir: $scratch,
       storeUrl: $storeUrl,
       storeScheme: $scheme,
       guarantee: $guarantee,
       credentialsInReach: ($creds | if . == "" then [] else split(" ") end),
       findings: (
         [ (if $isLocal | not then
              { id: "NOT_LOCAL", severity: "REJECT",
                detail: "the scratch store is \($scheme)://, which is not local. PREREG.md §14: this version promotes no byte produced by the untrusted candidate phase into durable storage, and a remote destination is a promotion whatever it is called." }
            else empty end),
           (if $isLocal and ($inside | not) then
              { id: "NOT_EPHEMERAL", severity: "REJECT",
                detail: "the scratch store at \($storeUrl) is outside the scratch directory \($scratch). A local path that outlives the run is durable storage with a shorter name." }
            else empty end),
           (if ($creds | length) > 0 then
              { id: "CREDENTIAL_IN_REACH", severity: "REJECT",
                detail: "these credential-shaped variables are set and non-empty: \($creds). The untrusted phase runs with none. Naming them rather than counting them, because a refusal that says how many is a refusal nobody can act on.",
                variables: ($creds | split(" ")) }
            else empty end),
           (if $knownGuarantee | not then
              { id: "GUARANTEE_UNNAMED", severity: "REJECT",
                detail: "\($guarantee) is not a guarantee this tool proves. PREREG.md §16: the check name states the exact guarantee, so an unnamed one cannot be run at all." }
            else empty end) ]),
       verdict: null }
     | .verdict = (if ([ .findings[] | select(.severity == "REJECT") ] | length) > 0
                   then "REFUSED" else "CLEARED" end)'
}

# The CHECK NAME. PREREG.md §16: it states the exact guarantee, always.
#
#   SOURCE_ORIGIN_INDEPENDENCE PASS
#   ESCROW_REPLAY FAIL
#
# and never a name that omits the guarantee and says only that some escrow
# check passed.
#
# THE FORBIDDEN PHRASE IS NOT WRITTEN OUT HERE, and that is deliberate rather
# than coy. The closed line DESIGN.md §19b: a refusal must not contain the
# words of the claim it is refusing to make, because a sentence that DENIES a
# claim looks exactly like one that makes it -- to a grep, to a search index,
# and to a reader skimming. The guard in tests/pg-unit.sh greps this tree for
# that phrase on a non-comment line, and a comment quoting it to forbid it was
# the first thing it found.
#
# A reader who sees only the check name must not be able to come away with a
# stronger belief than the run supports. The two guarantees are not
# interchangeable and the name is the only place most readers will ever look.
nse_pg_check_name() {
  local guarantee=$1 result=$2
  local upper
  case $guarantee in
    escrow-replay)               upper=ESCROW_REPLAY ;;
    source-origin-independence)  upper=SOURCE_ORIGIN_INDEPENDENCE ;;
    *) nse_pg_checker_error "refusing to name a check for the unknown guarantee $guarantee.
       An unnamed guarantee in a check name is how a weak result gets read as a
       strong one." ;;
  esac
  printf '%s %s\n' "$upper" "$result"
}

# ---------------------------------------------------------------------------
# nse_pg_scratch_run <installable> <guarantee> <scratch-dir> <report>
#
# The Nix-dependent half. Everything above runs anywhere.
# ---------------------------------------------------------------------------
nse_pg_scratch_run() {
  local installable=$1 guarantee=$2 scratch=$3 report=$4

  # CACH3, through the function that OBSERVES the result rather than assuming
  # it. `rm -rf` can fail on a path it cannot write, and a prepare that reports
  # success on a directory it did not empty is the exact shape this repository
  # refuses everywhere else.
  nse_pg_scratch_prepare "$scratch" \
    || nse_pg_checker_error "could not establish an EMPTY scratch store at $scratch.
       The acceptance test replays from a store that starts empty; a store that
       may hold objects from a previous run cannot support that claim, and a
       run that cannot support it does not proceed."
  [ "$NSE_PG_SCRATCH_WIPED" -eq 0 ] \
    || nse_pg_log "scratch: removed $NSE_PG_SCRATCH_WIPED leftover entries before starting"

  local store_url="file://$scratch/cache?compression=zstd"
  # Called as a STATEMENT, never in $( ). See the note on the function.
  nse_pg_scrub_credentials
  local scrubbed=$NSE_PG_SCRUBBED
  [ -z "$scrubbed" ] || nse_pg_log "scrubbed before anything ran: $scrubbed"
  local pre; pre=$(nse_pg_scratch_preflight "$scratch" "$store_url" "$guarantee")
  pre=$(printf '%s' "$pre" | nse_pg_jq --arg s "$scrubbed" \
          '. + { credentialsScrubbed: ($s | if . == "" then [] else split(" ") end) }')
  printf '%s\n' "$pre" > "${report%/*}/scratch-preflight.json"
  if ! printf '%s' "$pre" | nse_pg_jq_test '.verdict == "CLEARED"'; then
    printf '%s\n' "$pre" | nse_pg_jq -r '.findings[] | "PREFLIGHT " + .severity + " " + .id + ": " + .detail' >&2
    nse_pg_fail "the untrusted-phase preflight refused. Nothing was built, and no
       store was written to."
  fi

  nse_pg_step "SCRATCH  $installable  guarantee=$guarantee"
  nse_pg_log "store: $store_url (local, ephemeral, credential-free)"

  local t0 t1 rc=0
  t0=$(date +%s%N)
  # The CLOSED line does the work. It is invoked, not reimplemented.
  #
  # NSE_EXTRA_NIX_CONFIG is explicitly emptied rather than merely left unset:
  # the preflight checked the environment this function saw, and an exported
  # value could still arrive from a parent between then and here.
  NSE_EXTRA_NIX_CONFIG="" \
  "$NSE_ROOT/bin/nix-source-escrow" escrow "$installable" \
      --escrow-dir "$scratch" \
      --guarantee "$guarantee" \
      --staging-dir "${NSE_PG_STAGING:-$scratch/work/staging}" \
      > "$scratch/escrow.log" 2>&1 || rc=$?
  t1=$(date +%s%N)
  local ms=$(( (t1 - t0) / 1000000 ))

  local result=FAIL
  [ "$rc" -eq 0 ] && result=PASS
  local check; check=$(nse_pg_check_name "$guarantee" "$result")

  local oi=$scratch/evidence/origin-independence.json
  nse_pg_jq -n \
    --arg installable "$installable" --arg guarantee "$guarantee" \
    --arg scratch "$scratch" --arg storeUrl "$store_url" \
    --arg check "$check" --arg result "$result" \
    --argjson exitCode "$rc" --argjson ms "$ms" \
    --argjson preflight "$pre" \
    --slurpfile oi <(if [ -f "$oi" ]; then cat "$oi"; else printf 'null\n'; fi) \
    '{ schemaVersion: 1,
       kind: "policy-governed-scratch",
       installable: $installable,
       guarantee: $guarantee,
       checkName: $check,
       result: $result,
       exitCode: $exitCode,
       elapsedMilliseconds: $ms,
       scratch: { dir: $scratch, storeUrl: $storeUrl,
                  local: true, ephemeral: true, credentialFree: true,
                  durablePromotion: false },
       preflight: $preflight,
       acceptance: $oi[0] }' \
    | nse_pg_write_json "$report"

  printf '%s\n' "$check" >&2
  return "$rc"
}
