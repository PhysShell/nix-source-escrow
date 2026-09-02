# EVIDENCE — v0.1

Facts from an actual run, not a summary of intent. Reproduce with:

```bash
nix develop
nix-source-escrow escrow "path:$PWD/fixture#default"
```

The run below started by deleting `escrow/` entirely, so the staging store was
cold and every artefact was re-fetched from its origin before being preserved.
Machine-readable originals live in `escrow/evidence/*.json`; the block below is
`escrow/evidence/report.txt` verbatim, with the repository path shortened.

---

## Result

```text
ENVIRONMENT
NIX_VERSION=2.34.7
SYSTEM=x86_64-linux
HOST=Windows 11
EXECUTION_ENV=WSL2/NixOS 26.11 (Zokor)
KERNEL=Linux 6.18.33.2-microsoft-standard-WSL2
CLIENT_IS_TRUSTED_USER=true
AMBIENT_REQUIRE_SIGS=true
AMBIENT_HASHED_MIRRORS=(unset)

DISCOVERY
INSTALLABLE=path:<repo>/fixture#default
FLAKE_INPUTS=4
  INPUT_TREE_EDGES_WALKED=6
  INPUTS_UNRESOLVED_IN_LOCK=0
FOD_SOURCES=165
COVERED=163
EXTERNAL_RECOVERY=2
QUARANTINED=0
UNKNOWN=0
UNSUPPORTED=0
  HASH_MODE_FLAT=159  HASH_MODE_NAR=6
  WITH_POSTFETCH=3
  ON_KNOWN_FORGE=38
IFD_DETECTED=absent
EVAL_TIME_FETCH_STATIC_ENUMERATION=impossible
EVAL_TIME_FETCH_OFFLINE_PROBE=clean
ESCROW_DISCOVERY_COMPLETE=PASS
  note: eval-time builtins.fetch* are unenumerable statically, but evaluation succeeded offline with an empty cache under network isolation, so none needed the network
  note: 2 fixed-output source(s) have no origin URL at all (nixpkgs minimal-bootstrap); they can never be re-fetched upstream, only restored from a cache/escrow

ESCROW
BACKEND=local-file-binary-cache
URL=file://<repo>/escrow/cache
COMPRESSION=zstd
FLAKE_INPUTS_PRESERVED=4/4
SOURCES_REQUIRED_BY_PLAN=4
SOURCES_PRESERVED=4
SOURCES_MISSING=0
SOURCES_DISCOVERED_NOT_REQUIRED_BY_PLAN=161
OBJECTS_PRESERVED=874
OBJECTS_PRESENT=874/874
OBJECTS_NAR_VERIFIED=874/874
NAR_INTEGRITY_SCOPE=full-closure
NAR_INTEGRITY=OK
CONTENT_IDENTITY_VERIFIED=4
CONTENT_IDENTITY_MISMATCH=0
ESCROW_VERIFY=PASS

TRUST
REQUIRE_SIGS_DURING_PROBE=true
ESCROW_IS_SIGNED=false
ESCROW_KEY_IN_TRUSTED_PUBLIC_KEYS=false
SIGNING_KEYS_CREATED=0
  content-addressed source, no trusted keys      -> ok
  content-addressed source, cache.nixos.org key  -> ok
  input-addressed + signed, cache.nixos.org key  -> ok
  input-addressed + signed, no trusted keys      -> denied
  input-addressed + unsigned, cache.nixos.org key-> denied
SOURCE_SIGNATURE_REQUIRED=false
ESCROW_OBJECTS_CONTENT_ADDRESSED=820
ESCROW_OBJECTS_SIGNATURE_ONLY=53
ESCROW_OBJECTS_UNSIGNED_INPUT_ADDRESSED=1
TEST=PASS

NETWORK ACCEPTANCE
NETWORK_ISOLATION=user+network+mount namespace (unshare -Ur --net --mount)
ISOLATION_MODE=namespaces
NSS_ISOLATION=full
ORIGIN_HOSTS_PROVEN_UNREACHABLE=github.com,codeload.github.com,raw.githubusercontent.com,gitlab.com,ftp.gnu.org
ORIGIN_HOSTS_REACHABLE=none
CACHE_NIXOS_ORG_ALLOWED=false
OUR_ESCROW_ALLOWED=true
SUBSTITUTERS_ONLY_ESCROW=true
EFFECTIVE_SUBSTITUTERS=file://<repo>/escrow/cache
PROBE_METHOD=curl by name and by address pre-resolved outside the namespace
OFFLINE_EVAL_PROBE=clean
HTTP_FETCHES_IN_BUILD_LOG=0
REQUIRED_SOURCES_PRESENT_AFTER_BUILD=4/4
OUTPUT_PATH=/nix/store/kfmaahsrnil10qp66f3dnisv557bpa3a-escrow-fixture-0.1
OUTPUT_MATCHES_MANIFEST=true

ORIGIN_INDEPENDENCE=PASS
  probe github.com [140.82.121.4]: byName=false (curl 6), byAddress=false (curl 28)
  probe codeload.github.com [140.82.121.9]: byName=false (curl 6), byAddress=false (curl 28)
  probe raw.githubusercontent.com [185.199.110.133]: byName=false (curl 6), byAddress=false (curl 28)
  probe gitlab.com [172.65.251.78]: byName=false (curl 6), byAddress=false (curl 28)
  probe ftp.gnu.org [209.51.188.20]: byName=false (curl 6), byAddress=false (curl 28)
  probe cache.nixos.org [199.232.41.91]: byName=false (curl 6), byAddress=false (curl 28)
```

Timings and size, measured on a run that began by deleting `escrow/` and the
staging store, so nothing was reused:

| | |
|---|---|
| full suite from a cold escrow (`./tests/run-tests.sh`, `NSE_TEST_REUSE` unset) | **1383 s** — dominated by refetching ~650 MB into the staging store; the same suite against a warm escrow takes ~10 min |
| canonical pipeline (`escrow`) on a warm staging store | **75 s** |
| canonical pipeline with the staging store also cold | ~2 min on a fast link; the staging refill is the whole cost and is network-bound |
| acceptance test alone | ~30–60 s |
| escrow on disk | **87 MB**, 874 objects, zstd |
| staging store (throwaway) | ~650 MB |

The suite has two modes and both are exercised here: the default re-creates the
escrow from nothing, and `NSE_TEST_REUSE=1` reuses an existing one. The
acceptance test itself is unaffected by that choice — it always starts from an
empty test store with a cold fetcher and eval cache.

`nix flake check` (shellcheck over every script): **pass**.

---

## Why the network result is believable

Four things had to be true at once, and each is recorded in
`escrow/evidence/origin-independence.json`:

1. **The store was empty.** The build ran against a store directory created
   moments earlier, with `HOME` and `XDG_CACHE_HOME` pointed at a fresh
   directory so Nix had neither a warm fetcher cache nor a warm eval cache. A
   source cannot have been "already there".
2. **Nothing was reachable, and that was measured rather than assumed.** Each
   origin was probed twice: by name, and by an address resolved *before*
   entering the namespace. The by-name probes fail with `curl 6` (no
   resolution) and the by-address probes with `curl 28` (timeout — no route).
   "You only broke DNS" is not available as an explanation. `NSS_ISOLATION=full`
   records that the host's `nscd` socket was masked too, since a network
   namespace does not isolate it.
3. **The verdict checked the environment before the result.** Isolation mode,
   origin reachability, resolvability-before-isolation, and the substituter list
   are all decided *before* the build outcome is considered. `--no-isolation`
   yields `NOT_ISOLATED`, a third verdict that can never be `PASS`.
4. **Evaluation itself happened offline.** A dedicated probe forces evaluation
   to complete inside the namespace with an empty cache, before the build. This
   is the only thing that can cover eval-time `builtins.fetch*`, which cannot be
   enumerated statically at all.

And the build produced the exact store path the manifest predicted before the
network was cut.

The test can also go red. `t08` deletes only the plan-required source objects
and re-runs: the build fails. `t12` runs two adversarial cases — a control run,
and a run that *claims* isolation while having none — and requires both to
refuse.

## Automated tests

`nix develop -c ./tests/run-tests.sh` — **72/72 passed**.

| group | what it pins down |
|---|---|
| `t01` | discovery: the input tree is walked transitively; a renamed lock node resolves by graph, not by alias; a `follows` edge deduplicates to one object; `fetchFromGitHub` recognised as recursive-hash with `postFetch`; flat `fetchurl` recognised; nothing left `UNKNOWN`/`UNSUPPORTED`; IFD probe answers definitely |
| `t02` | manifest: valid JSON, every source carries the full record, every status is from the documented model, no timestamps in the canonical file |
| `t03` | preservation: every discovered input and all plan-required sources present; `verify` passes; NAR integrity covers the **whole closure**, and the verified count equals the closure size |
| `t04` | idempotency: `discover` deterministic, manifest byte-identical after a second `preserve` |
| `t05` | a missing source object makes `verify` fail, attributed to presence |
| `t06` | a corrupted NAR fails on integrity; a tampered `CA:` field fails on content identity — two different checks, two different verdicts |
| `t07` | **the acceptance criterion**, plus: zero origins reachable, probes used real pre-resolved addresses, the escrow was the only substituter, evaluation succeeded offline, zero http fetches, output path matches, sources present in the clean store, NSS isolated, inputs restored offline, and the report names only hosts *proven* unreachable |
| `t08` | **negative control** — escrow with sources removed must FAIL |
| `t09` | trust, measured: the five-case table below is asserted, so a change in Nix's behaviour breaks the build instead of silently invalidating the design |
| `t10` | `postFetch`: **one URL, three distinct Nix identities**, with `stripRoot` isolated as the only variable between two of them |
| `t11` | flake inputs are locked to a real forge that was demonstrably unreachable, and every one of them — transitive included — was served from the escrow |
| `t12` | **isolation guard**: a control run yields `NOT_ISOLATED` and exits non-zero; a run that claims isolation but has none is caught by the connectivity probes alone |

Two checks earned their keep during development. `t06`'s content-identity check
caught a bug in the *test harness* that wrote through a hardlink and corrupted a
real narinfo in the escrow. And `t12` exists because the acceptance test really
did report `ORIGIN_INDEPENDENCE=PASS` with exit 0 while GitHub was reachable —
see below.

---

## Defects found in review, and what changed

An external review of the first iteration found five. All are fixed and each now
has a test that fails if it returns.

| | defect | fix |
|---|---|---|
| **P1** | `--no-isolation` returned `ORIGIN_INDEPENDENCE=PASS` and exit `0` while GitHub, GitLab and ftp.gnu.org were all reachable. The verdict was computed from build outcomes only. The report also listed those reachable hosts as `ORIGIN_HOSTS_BLOCKED`, printing intent as if it were a finding. | Verdict is now ordered, environment first: isolation mode → origin reachability → resolvability before isolation → substituter list → only then the build. `NOT_ISOLATED` is a distinct verdict. Reporting renamed to `ORIGIN_HOSTS_PROVEN_UNREACHABLE`, computed from probe results. Tests `t12.1`–`t12.6`. `DESIGN.md` §11. |
| **P1** | `OBJECTS_VERIFIED=870` overstated: NAR integrity was recomputed for 5 source paths, the other 865 were only checked for narinfo presence. | NAR verification now covers the full closure by default. The report prints `OBJECTS_PRESENT`, `OBJECTS_NAR_VERIFIED` and `NAR_INTEGRITY_SCOPE` as separate lines. Tests `t03.6`–`t03.7`. |
| **P2** | Flake-input discovery read only root inputs and assumed the alias equalled the lock node id, so transitive inputs, `follows` and renamed nodes could be missing from the manifest and from verification. | Discovery now walks the full archive tree and the lock node graph in lockstep, resolves `follows` arrays from the root, and deduplicates by store path. The fixture was extended to contain all four cases. Tests `t01.2a`–`t01.2e`. `DESIGN.md` §6. |
| **P2** | `ESCROW_DISCOVERY_COMPLETE=PASS` while the same report admitted eval-time `builtins.fetch*` were unenumerated — the exact "`UNKNOWN` silently becomes `PASS`" failure the status model exists to prevent. | Added an offline evaluation probe inside the acceptance test, and a third value: completeness is `UNVERIFIED` until that probe has passed under real isolation. Test `t07.10`. `DESIGN.md` §5. |
| **P2** | The `postFetch` test claimed "one URL, three identities", but the third identity (`fetchFromGitHub`) came from a *different* URL, and no test isolated `stripRoot` as a single variable. | The fixture gained a fourth source: `fetchzip` of the same URL with `stripRoot = true`. Three identities now genuinely come from one URL, and two of them differ in exactly one attribute. `fetchFromGitHub` is asserted separately. Tests `t10.1`–`t10.6`. `DESIGN.md` §3. |

---

## KNOWN_GAPS

Honest list. None of these are hidden behind a green result.

**Scope of the guarantee**

1. `FULL_AIRGAP_REBUILD` is **not** demonstrated and is not implied. The escrow
   contains prebuilt binaries that came from `cache.nixos.org` with its
   signatures. Rebuilding from source with no trusted binary substituter is a
   different claim needing the whole bootstrap source corpus and, per the trust
   table, signing.
2. **161 of 165 discovered sources are not preserved.** They are the nixpkgs
   bootstrap sources, never fetched because their consumers arrive as prebuilt
   binaries. Reported explicitly as `SOURCES_DISCOVERED_NOT_REQUIRED_BY_PLAN`.
   Mirroring them is `nixpkgs-swh`'s job.
3. The guarantee is per-installable and per-system. Other outputs of the same
   flake, other systems, or a different `nixpkgs.config` produce a different
   graph and need their own run.

**Discovery**

4. Eval-time `builtins.fetchTarball` / `fetchGit` / `fetchurl` with a pinned
   hash **cannot** be enumerated statically — not "not yet implemented",
   impossible at this layer. They are covered only *behaviourally*, by the
   offline evaluation probe. What that probe establishes is precise, and worth
   stating exactly: every eval-time fetch on this path was satisfiable with no
   network and an empty cache — either because there are none, or because the
   fetched object was already in the escrow. What it does **not** do is
   enumerate them, so they never appear in the manifest as individual records
   with an origin and a hash. A per-source model for them would need an
   evaluation-tracing hook Nix does not currently expose. The fixture contains
   none, so the failing branch of the probe is untested against a real case.
5. Dynamic derivations and floating content-addressed outputs are reported
   `UNSUPPORTED` (the output path is read from `env.<outputName>`, which they do
   not have). The fixture contains none, so the `UNSUPPORTED` branch is asserted
   to be zero but never observed non-zero in a real graph.
6. IFD is probed on this evaluation path only, and this fixture has none. A
   project with IFD would report `ESCROW_DISCOVERY_COMPLETE=PARTIAL`; that
   branch is untested against a real IFD project.
7. The flake-input walk is validated against the four cases in the fixture
   (nested, renamed node, `follows`, shared store path). Deeper pathologies —
   `follows` chains several levels down, inputs overridden at the CLI — are
   handled by construction but not exercised by a test.

**Recovery**

8. **No Software Heritage bridge.** The ExtID → SWHID → vault-cook → verify
   model is researched and written down (`DESIGN.md` §1) but **not implemented
   and not validated**. No claim of SWH recoverability is made here.
9. **`postFetch` replay is unsolved** (`DESIGN.md` §3). Recovering the upstream
   artefact from any archive does not reconstruct a `fetchzip`-class output; you
   must replay unpack + `stripRoot` + the caller's shell in the same `stdenv`
   and land on the same NAR hash. This is the blocker for item 8, and it is a
   design constraint, not a TODO.
10. `RECOVER` in v0.1 means "the origin, or the escrow". There is no repair path
    for the two `EXTERNAL_RECOVERY` sources beyond the escrow itself and the
    manual `nix-store --add-fixed` procedure nixpkgs documents.

**Mechanism**

11. The acceptance test needs unprivileged user namespaces. It will not run
    where those are disabled.
12. The test depends on a **behavioural workaround for Nix 2.34.7**: Nix
    disables all substituters, including `file://` ones, when it decides there
    is no Internet, so the namespace carries a dummy interface with a route to
    nowhere (`DESIGN.md` §8). If a future Nix changes that heuristic, revisit.
    The workaround does not weaken the isolation — the by-address probes prove
    it, and `t12` proves the verdict does not depend on trusting it.
13. Trust results are measured on Nix 2.34.7 with this daemon configuration.
    `t09` will fail loudly if that changes, which is the intent.
14. The escrow is one local directory. No replication, no GC policy, no
    multi-user access control, no S3 backend. Deliberate for v0.1.
15. `preserve` requires network — it is the step that fetches from origins while
    they still exist. Only `verify` and the acceptance test are offline.
16. The acceptance test proves the *escrow* served the sources by elimination
    (empty store, no route, escrow-only substituters). It does not parse
    per-object provenance out of the Nix log.

---

## What to do next

In the order the value arrives, and not before this iteration is trusted:

1. S3/MinIO backend for the escrow (the `file://` layout maps over directly).
2. Flat-`fetchurl` hashed-mirror layer, reusing the `copy-tarballs.pl` key
   scheme, for sharing tarballs between organisations.
3. Renovate / `update-flake-lock` integration: run `preserve → verify →
   test-origin-independence` as a required check on the update PR, so a
   dependency bump cannot merge until its sources are in escrow.
4. A `postFetch` replay experiment (gap 9) — the prerequisite for any honest
   Software Heritage bridge.
5. Then, and only then, the SWH repair bridge (gap 8).
6. Explicit IFD / manual-escrow policy, with a real IFD project as the fixture.
7. `FULL_AIRGAP_REBUILD` as a separate, separately-named guarantee.
