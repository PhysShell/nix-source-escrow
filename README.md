# nix-source-escrow

Keep the sources a Nix build depends on in storage **you** control, and prove
with a test that the build survives the death of their origins.

Status: **v0.1 proof of concept.** One guarantee, one fixture, real evidence.

---

## Problem

Nix pins *identity* extremely well — a revision, a hash, a store path. It does
not pin *availability*. The `narHash` in your `flake.lock` and the
`outputHash` of every `fetchFromGitHub` remain perfectly correct after the
repository is deleted, renamed, made private, or DMCA'd. They are correct and
useless.

So a GitHub outage, an author's decision to delete a repo, or a forge going
away quietly becomes part of your availability guarantee, whether you agreed to
that or not.

We are not trying to fix Nix. We are trying to answer one question with a test
instead of a hope:

> For a dependency graph you have already accepted, are the source inputs in
> storage you control — and does the build still work when the origins are gone?

## Guarantee, v0.1

**`ORIGIN_INDEPENDENCE`** — the accepted build completes while every dependency
origin is unreachable, using only the escrow.

The acceptance test runs the build in an unprivileged network namespace with no
route to anything, from a **store that starts empty** and a **cold fetcher and
eval cache**. Origins are probed both by name and by an address resolved before
entering the namespace, so "it only broke DNS" is not an available explanation.

In this repository, on the machine in `EVIDENCE.md`, that test passes.

### Explicitly *not* the guarantee

**`FULL_AIRGAP_REBUILD`** — rebuilding everything from source with no trusted
binary substituter — is a different, larger claim. The escrow here holds
prebuilt binaries that originally came from `cache.nixos.org` with its
signatures. A green `ORIGIN_INDEPENDENCE` does not imply B, and this repo never
says it does. See `DESIGN.md` §9.

## Non-goals

Not built, on purpose:

* a dependency updater — Renovate, `update-flake-lock`, `nix-update` and
  `nvfetcher` exist. The escrow is a **gate around their output**:
  `candidate -> preserve -> verify -> acceptance test -> only then mergeable`;
* a replacement for `fetchFromGitHub` or any fetcher;
* a binary-cache protocol, an object store, or a cache server (a directory is
  enough to prove the guarantee);
* a custom Nix daemon, a build proxy, a GUI, a provenance database, an SBOM
  framework, GC or replication policy;
* a Software Heritage bridge. SWH is prior art and a plausible *repair* backend,
  not our substituter, and a correct bridge is blocked on a real problem —
  `DESIGN.md` §1 and §3.

## Architecture

```
        UPDATE  (someone else's job: Renovate / update-flake-lock / nix-update)
                                  |
                                  v  candidate flake.lock
   +------------------------------------------------------------------+
   |  DISCOVER   nix derivation show -r   -> fixed-output sources      |
   |             nix flake archive --json -> flake inputs              |
   |             status per source: COVERED / EXTERNAL_RECOVERY /      |
   |                                QUARANTINED / UNKNOWN / UNSUPPORTED|
   +------------------------------------------------------------------+
                                  |
   +------------------------------------------------------------------+
   |  PRESERVE   build into a fresh staging store (never trust yours)  |
   |             nix flake archive --to  |  nix copy --to              |
   |                     -> escrow/cache : a file:// binary cache      |
   +------------------------------------------------------------------+
                                  |
   +------------------------------------------------------------------+
   |  VERIFY     narinfo present? CA == the derivation's outputHash?   |
   |             nix store verify (NAR integrity)                      |
   |  TRUST      measure what Nix accepts unsigned                     |
   +------------------------------------------------------------------+
                                  |
   +------------------------------------------------------------------+
   |  PROVE      unshare -Ur --net --mount, empty store, cold caches   |
   |             probe reachability (by name AND by address)           |
   |             evaluate offline  <- the only cover for eval-time     |
   |                                  builtins.fetch*                  |
   |             build                                                 |
   |   ORIGIN_INDEPENDENCE = PASS | FAIL | NOT_ISOLATED                |
   +------------------------------------------------------------------+
                                  |
                   RECOVER (v0.1: origin only; SWH = extension point)
```

## Reproduce

Requires Linux with unprivileged user namespaces. Developed on WSL2 / NixOS,
Nix 2.34.7. No root, no changes to your system or user Nix configuration.

```bash
git clone <this repo> && cd nix-source-escrow
nix develop                       # jq, curl, iproute2, util-linux, shellcheck

# everything, end to end (~3 min, ~90 MB of escrow)
nix-source-escrow escrow "path:$PWD/fixture#default"
```

Or one stage at a time:

```bash
nix-source-escrow env
nix-source-escrow discover                 "path:$PWD/fixture#default"
nix-source-escrow preserve                 "path:$PWD/fixture#default"
nix-source-escrow verify                   "path:$PWD/fixture#default"
nix-source-escrow trust-probe
nix-source-escrow test-origin-independence "path:$PWD/fixture#default"
nix-source-escrow report
```

Tests:

```bash
# default: re-creates the escrow from nothing, then runs every test
nix develop -c ./tests/run-tests.sh

# faster: reuse an existing escrow (the acceptance test is unaffected --
# it always starts from an empty test store with cold caches either way)
nix develop -c env NSE_TEST_REUSE=1 ./tests/run-tests.sh

nix flake check                                            # shellcheck
```

The negative control on its own — the escrow with its sources deleted must
**fail**:

```bash
nix-source-escrow test-origin-independence "path:$PWD/fixture#default" \
  --escrow-dir ./escrow/work/tests/nosource --expect-fail
```

## Output

```
escrow/
  cache/                        the escrow: a file:// binary cache
  discovery.json                what was found  (canonical, deterministic)
  manifest.json                 what is preserved (canonical, deterministic)
  closure.json                  every preserved store path (sorted)
  evidence/
    environment.json            probe data, timestamped, kept out of the manifest
    verify.json
    trust.json
    origin-independence.json
    report.txt
  work/                         staging store, test store, logs (throwaway)
```

`manifest.json` and `discovery.json` carry no timestamps, so re-running does not
churn them — test `t04` asserts byte-identical output across runs. Anything with
a timestamp lives under `evidence/`.

One source record:

```json
{
  "kind": "fetchzip-like",
  "name": "source",
  "origin":  { "urls": ["https://github.com/NixOS/nix-pills/archive/4df9718....tar.gz"],
               "hosts": ["github.com"], "knownForge": true },
  "expectedHash": "sha256-MIMqNvR3oazdybbVbQv/gF3oY7Tzma6NgRYedJGdqz0=",
  "hashMode": "nar",
  "storePath": "/nix/store/jfsjyv5dg7zmnjxk5fb04ax822nzmh0i-source",
  "transform": { "postFetch": true, "stripRoot": true,
                 "downloadToTemp": true, "recursiveHash": true },
  "discovery": { "method": "nix derivation show -r; outputs[*].hash != null",
                 "status": "COVERED" },
  "escrow": { "backend": "local-file-binary-cache", "present": true,
              "status": "COVERED" },
  "plan": { "requiredByPlan": true }
}
```

A note on `rev`: flake inputs carry `rev` and `narHash` straight from
`flake.lock`, which is authoritative. Fetcher-based sources do **not** get a
synthesised `rev` field — a derivation does not carry one, and parsing it back
out of the URL would be a guess dressed as a fact. Their identity is
`origin.urls` (which contains the revision verbatim) plus `expectedHash`, which
is what Nix itself uses.

## The fixture

`fixture/` is a small, fully pinned flake chosen to exercise the cases that
break naive implementations, not to be big:

| | what it exercises |
|---|---|
| `nixpkgs`, `gitignore-src` (`flake = false`) | flake inputs from a real forge, one of them not a flake |
| `flake-utils` + `systems` | a **nested** input tree, and a **renamed** lock node (root's `systems` is node `systems_2`) |
| `flake-utils-follows` | a `follows` edge, and two aliases resolving to **one** store path |
| `fetchFromGitHub` (nix-pills) | `fetchzip` -> recursive NAR hash, `postFetch`, `stripRoot = true` |
| `fetchurl` (hello tarball) | flat hash — the hashed-mirror case |
| `fetchzip`, same URL, `stripRoot = false` | recursive hash of the same bytes |
| `fetchzip`, same URL, `stripRoot = true` | isolates `stripRoot` as the only variable |

The last three rows are the point: **one URL, three different fixed-output
hashes**, with `stripRoot` isolated between the last two. Anything that
"recovers the upstream artefact" reconstructs none of them. See `DESIGN.md` §3.

The flake-input rows exist to break naive discovery: reading only root inputs
misses `flake-utils/systems`, and resolving lock nodes by alias name picks the
wrong `systems`.

## Honesty rules this repo follows

* **`UNKNOWN` never silently becomes `PASS` — including for this tool itself.**
  `ESCROW_DISCOVERY_COMPLETE` has three values: `PARTIAL` when something is
  known-incomplete, `UNVERIFIED` when nothing is known-incomplete but the
  offline evaluation probe has not passed under real isolation, and `PASS` only
  when both hold. Eval-time `builtins.fetch*` cannot be enumerated statically,
  so a clean static pass alone is not enough.
* **The acceptance verdict checks the environment before the result.** A build
  that succeeds while GitHub is reachable proves nothing, so isolation mode and
  actual reachability are decided first; `--no-isolation` yields a distinct
  `NOT_ISOLATED` verdict that can never be `PASS`. `DESIGN.md` §11.
* **The report states what was demonstrated, not what was intended.**
  `ORIGIN_HOSTS_PROVEN_UNREACHABLE` is computed from probe results. Each origin
  is probed twice — by name, and by an address resolved before isolation — so
  "you only broke DNS" is not available as an explanation.
* **Presence is not verification.** `OBJECTS_PRESENT` counts narinfos;
  `OBJECTS_NAR_VERIFIED` counts objects whose NAR hash was recomputed, and
  `NAR_INTEGRITY_SCOPE` says which set that was. They are separate lines
  because conflating them reports a merely-populated escrow as verified.
* **Discovered is not preserved.** The report separates
  `SOURCES_REQUIRED_BY_PLAN` from `SOURCES_DISCOVERED_NOT_REQUIRED_BY_PLAN`
  (the nixpkgs bootstrap, which is `nixpkgs-swh`'s problem, not ours).
* **The test can fail.** It starts from an empty store with cold caches, and
  the negative controls (`t08`, `t12`) prove it goes red — for a missing source,
  for a missing namespace, and for isolation that is claimed but absent.
* **No claim about Software Heritage recoverability is made**, because none has
  been demonstrated. `DESIGN.md` §1 and §3.

## Further reading

* `DESIGN.md` — the decisions worth arguing about, with measurements.
* `EVIDENCE.md` — the actual result from the last run, machine-readable.
