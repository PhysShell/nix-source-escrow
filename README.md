# nix-source-escrow

Keep the sources a Nix build depends on in storage **you** control, and prove
with a test that the build survives the death of their origins.

Status: **proof of concept.** Two implemented guarantees, one fixture, evidence
you can re-run. The escrow is any Nix store you control; the product is the
proof around it, not the storage.

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

## Guarantees

Three tiers, named separately, because one word covering all of them is how a
cheap claim gets quoted as an expensive one.

| guarantee | the escrow holds | the test allows | status |
|---|---|---|---|
| `SOURCE_ORIGIN_INDEPENDENCE` | source material only: plan-required fixed-output sources, flake inputs, the flake source | the escrow **plus** a replica of your approved binary tier (`--binary-tier`), filled from that tier and from nothing else | implemented, `--guarantee source-origin-independence` |
| **`ESCROW_REPLAY`** | the whole realised closure | the escrow **only** | implemented, **default** |
| `FULL_AIRGAP_REBUILD` | the whole bootstrap source corpus | the escrow only, and every derivation rebuilt from source | **not implemented**, see `DESIGN.md` §12 |

The acceptance test runs the build in an unprivileged network namespace with no
route to anything, from a **store that starts empty** and a **cold fetcher and
eval cache**. Origins are probed both by name and by an address resolved before
entering the namespace, so "it only broke DNS" is not an available explanation.

`ESCROW_REPLAY` is the default because it is the strongest claim this harness
can demonstrate — nobody should get the weaker one by accident.
`SOURCE_ORIGIN_INDEPENDENCE` exists because the strong one puts the **entire
realised closure** — 876 objects, 87 MB, for a fixture that consumes five
sources — into the set you must **retain durably and be able to audit**, for
every revision you gate. The cost is a retention obligation, not transfer: a
content-addressed store deduplicates, so a bump does not re-copy 876 objects,
and anyone who reads it that way will rightly doubt the rest of the paragraph.
What grows is the set of objects you have promised to keep. It proves that losing the *source origins* does not break the build, and
it says out loud, in the report, that it proves nothing about losing the binary
tier.

Its prebuilt objects are copied **from the approved tier you name**, never from
whatever this machine happened to build — otherwise the evidence would claim
"works given the approved cache" about a cache that never held the object.
Anything neither escrowed nor held by that tier is handed to nobody, and the
acceptance build has to produce it: whether it can is the test's answer to
give, not something the tool predicts from a signature or a guess.
`DESIGN.md` §12.

### Explicitly *not* the guarantee

`FULL_AIRGAP_REBUILD` is a different, larger claim. The escrow here holds
prebuilt binaries that originally came from `cache.nixos.org` with its
signatures. A green `ESCROW_REPLAY` does not imply it, and this repo never says
it does. It also needs signing, for a reason that was measured rather than
assumed — `DESIGN.md` §4 and §9.

## Where the escrow lives

The escrow is a **URL**, not a directory:

```bash
# the default: a file:// binary cache under ./escrow
nix-source-escrow escrow "path:$PWD/fixture#default"

# an Attic / S3 / Artifactory Nix repository you already run
nix-source-escrow escrow ".#default" \
  --escrow-store       "s3://our-escrow?region=eu-west-1" \
  --escrow-substituter "https://cache.example.com/escrow"
```

`--escrow-store` is where `preserve` writes; `--escrow-substituter` is what
`verify` and the acceptance test read. They are two settings because once the
escrow stops being a directory on your laptop, "the store I push to" and "the
substituter a consumer configures" stop being the same string. Backend
credentials go through `NSE_EXTRA_NIX_CONFIG` (`netrc-file`, `access-tokens`,
the `aws-*` settings) — this tool adds no credential handling of its own.

**A remote escrow is a first-class storage target, not a first-class acceptance
target.** The acceptance test cuts all egress, so `https://attic.example.com`
is exactly as unreachable inside the namespace as `github.com` is. Pointing
`substituters` at it in there and calling a green build a proof would be a lie
about which store served the bytes. Instead a non-local escrow is
**materialised into a local proof replica before isolation**, and the test
replays from that. The evidence records both ends and which one the test used:

```
DURABLE_ESCROW=https://attic.example.com/escrow
REPLAYED_FROM=file:///…/work/proof-replica/escrow (materialised, 874 objects)
```

What that establishes: the durable escrow was asked for every object and
produced it, and that exact set then replays the build with no network. What it
does not establish: that the durable store is reachable during a blackout. That
is its own availability problem, and not what this project is for.
`DESIGN.md` §13.

## Non-goals

Not built, on purpose:

* a dependency updater — Renovate, `update-flake-lock`, `nix-update` and
  `nvfetcher` exist. The escrow is a **gate around their output**:
  `candidate -> preserve -> verify -> acceptance test -> only then mergeable`;
* a replacement for `fetchFromGitHub` or any fetcher;
* a binary-cache protocol, an object store, or a cache server — the escrow is
  whatever Nix store you already run, addressed by URL. A `file://` directory
  is the default because it is enough to prove the guarantee, not because it is
  the architecture;
* a custom Nix daemon, a build proxy, a GUI, a provenance database, an SBOM
  framework, GC or replication policy;
* a Software Heritage bridge. SWH is prior art and the right *repair* backend,
  not a substituter — there is no `narinfo` endpoint and the vault cook is
  asynchronous. The recovery algorithm is written down (exact `nar-sha256`
  ExtID lookup first, reconstruction only on a miss) and **not implemented
  here**; `DESIGN.md` §1 and §3.

## The part of this that is not about Nix

Eighteen runs produced five defects in the implementation, **six in the
instruments meant to catch them**, and one sampling design that refuted a
correct hypothesis. A test that asserted `0 == 0` about a command that never
ran. A probe whose own invocation determined its answer. An assertion that
could pass only while the code under it was fail-open. A fixture in a shape the
real tool never emits.

The rule that came out of it is one sentence, and it is in
**[`EXPERIMENT-PROTOCOL.md`](EXPERIMENT-PROTOCOL.md)** with no Nix in it,
because that is the part that transfers:

> Before relying on a check, state the observable trace that would make it
> report failure. If you cannot describe one, or the construction of the check
> cannot produce one, it is not a check.

`DESIGN.md` §15–§18 are the case histories behind each line of it.

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
   |             nix flake archive --to  |  nix copy --to  (batched)   |
   |                     -> --escrow-store URL                         |
   |                        file:// (default) | s3:// | https:// | ... |
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
   |             substituters := --escrow-substituter URL              |
   |             probe reachability (by name AND by address)           |
   |             evaluate offline  <- the only cover for eval-time     |
   |                                  builtins.fetch*                  |
   |             build                                                 |
   |   ORIGIN_INDEPENDENCE = PASS | FAIL                               |
   |       | NOT_ISOLATED | HARNESS_ERROR | MODE_UNSUPPORTED           |
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
# shell-level units: no Nix, no network, no namespaces. Runs anywhere.
./tests/unit-shell.sh

# default: re-creates the escrow from nothing, then runs every test
nix develop -c ./tests/run-tests.sh

# faster: reuse an existing escrow (the acceptance test is unaffected --
# it always starts from an empty test store with cold caches either way)
nix develop -c env NSE_TEST_REUSE=1 ./tests/run-tests.sh

# skip the second, source-only escrow if you only want the strict mode
nix develop -c env NSE_TEST_SKIP_MODES=1 ./tests/run-tests.sh

nix flake check                                            # shellcheck

# the packaged executable, which is the only way to test that the revision
# really is stamped into the build rather than read out of a .git that is
# not there
nix build .#nix-source-escrow
./result/bin/nix-source-escrow --help
```

Two workarounds in the acceptance harness — a `dummy0` route-to-nowhere
interface and a manual pre-copy of locked flake inputs — were carried as
hypotheses, measured by an experiment (`E0`–`E3`), and then **deleted**.
`E1`/`E2`/`E3` came back `CONFIRMED` on Nix 2.34.7 *and* 2.24.9, in every run
from 6 to 11, each with a green `E0` baseline. The experiment was retired with
its subject: with no flag left to disable, the default acceptance path *is* the
configuration it validated, and `t07`, `t15` and `t16` exercise it on every
run. `DESIGN.md` §8, §8a and §17a; the rules for reading any future experiment
survive in `lib/experiment.sh`.

The rule that made those readings worth anything is the part kept in
`lib/experiment.sh`: a broken escrow makes every variant fail, so a naive
`FAIL → REFUTED` writes a confident "the workaround IS needed" that no run
supports. A baseline that is not green means the variants are not run at all
and are recorded `INCONCLUSIVE`, and a composed hypothesis stays inconclusive
until its parts hold on their own. `u10` and `u17` keep both honest.

The negative control on its own — the escrow with its sources deleted must
**fail**:

```bash
nix-source-escrow test-origin-independence "path:$PWD/fixture#default" \
  --escrow-dir ./escrow/work/tests/nosource --expect-fail
```

The cheap guarantee, sharing one staging store so the closure is fetched once:

```bash
nix-source-escrow escrow "path:$PWD/fixture#default" \
  --escrow-dir ./escrow-src \
  --guarantee source-origin-independence \
  --staging-dir ./escrow/work/staging
```

## Output

```
escrow/
  cache/                        the escrow, when the backend is the default file://
  replica/                      SOURCE_ORIGIN_INDEPENDENCE only: the stand-in for
                                your approved binary tier. NOT part of the escrow
                                and not meant to be archived with it
  discovery.json                what was found  (canonical, deterministic)
  manifest.json                 what is preserved (canonical, deterministic)
  closure.json                  every preserved store path, split into
                                escrowPaths / replicaPaths
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
* **A failed run produces MORE evidence, not less.** The report is written on
  success, on failure, and on an abort partway through — stages that did not
  run print `NOT_RUN` rather than vanishing. The v0.1 CLI got this backwards:
  `set -e` plus an acceptance test returning 1 killed the process before the
  report was written, so the report went missing exactly when it was needed.
* **A broken harness is its own verdict, and so is an unmodellable claim.**
  Every isolation step is checked, and a half-applied namespace yields
  `HARNESS_ERROR`. A guarantee the harness cannot model on these inputs — an
  escrow preserved for one guarantee, proven against another — yields
  `MODE_UNSUPPORTED`. Neither is a `FAIL` that reads as an accusation against
  the escrow, and neither is accepted by `--expect-fail` as a negative control.
  What is *not* one of these: a cache that lacks a path. That is a data
  condition a real build can resolve by building the thing, and the build is
  left to answer it.
* **Empty is data only after a successful parse.** `MISSING`, `UNPARSEABLE` and
  `UNKNOWN_SCHEMA` are not `EMPTY`, and where a build plan guarantees a
  non-empty result, observing zero is `FAIL`/`UNVERIFIED` and never `PASS`.
  This is not a slogan: the first real execution found three separate defects
  that were all this one mistake, each producing a confident green report about
  nothing. `DESIGN.md` §15 and §16.
* **Requested is not reachable.** `nix copy` copies closures, so the stores the
  test can actually read are listed and counted, not inferred from the size of
  the request. Anything the manifest says is provided to nobody but turns out
  to be reachable is a `FAIL`: anything the build needed from that set could
  then have been obtained rather than built.
* **Every result names the code that produced it.** Each evidence file carries
  `provenance` — revision, where that revision came from, dirty flag, Nix
  version, and the SHA-256 of the manifest and closure it judged — and the
  report prints `TOOL_COMMIT`. For a packaged build the revision is stamped in
  at build time, because an installed `/nix/store` tree has no `.git` to ask
  and no working tree to be dirty. A `CONFIRMED` with no revision attached is a
  rumour. `DESIGN.md` §14.
* **The report says which machine, and how it knows.** `HOST` is detected and
  printed alongside `HOST_DETECTED_BY`. An earlier version printed a
  hardcoded `HOST=Windows 11` on every machine, in a tool whose stated rule is
  the line above it — and that literal reached `EVIDENCE.md` as a measured
  fact. Test `u05`/`t13` and a source-wide grep now make it a build failure.
* **Cited is not measured.** Coverage figures borrowed from other projects
  (`DESIGN.md` §1) are labelled as citations, with the caption they actually
  support — a per-snapshot percentage is not historical coverage, and
  "successfully disassembled" is not "recoverable end to end".
* **No claim about Software Heritage recoverability is made**, because none has
  been demonstrated. `DESIGN.md` §1 and §3.

## Further reading

* `DESIGN.md` — the decisions worth arguing about, with measurements.
* `EVIDENCE.md` — the actual result from the last run, machine-readable.
