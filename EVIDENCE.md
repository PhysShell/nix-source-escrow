# EVIDENCE

Facts from an actual run, not a summary of intent. Reproduce with:

```bash
nix develop
nix-source-escrow escrow "path:$PWD/fixture#default"
```

> **Status of this file.** The report block below is the **v0.1.0** run,
> verbatim. It predates the second review and the changes made in response to
> it, and it is kept because it is the record of what was actually measured
> then — including, in plain sight on the third line, the `HOST=Windows 11`
> literal that this file used to present as a measured fact.
>
> It is **not** the current output. The current report prints extra lines
> (`HOST_DETECTED_BY`, `GUARANTEE`, `ISOLATION_SETUP`, `DUMMY_INTERFACE`,
> `FLAKE_INPUT_RESTORE`, `STORE_URL` / `SUBSTITUTER_URL`), `manifest.json` and
> `closure.json` are at schema 2, and `origin-independence.json` carries a
> `guarantee` object, and every evidence file now carries a `provenance` block.
> **Re-run before quoting any of this**, and replace the block with the new
> output. Nothing below has been re-measured on the current
> code; the shell-level units (`tests/unit-shell.sh`, 69 checks) are the only
> part of this change set with a recorded result, and they pass.

The v0.1.0 run below started by deleting `escrow/` entirely, so the staging
store was cold and every artefact was re-fetched from its origin before being
preserved. Machine-readable originals live in `escrow/evidence/*.json`; the
block below is `escrow/evidence/report.txt` verbatim, with the repository path
shortened.

---

## Result (v0.1.0, superseded)

```text
ENVIRONMENT
NIX_VERSION=2.34.7
SYSTEM=x86_64-linux
HOST=Windows 11          <-- the defect: a literal, printed on every machine
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

`./tests/unit-shell.sh` — **69/69 passed** on the current code (no Nix needed).

`nix develop -c ./tests/run-tests.sh` — **72/72 passed on v0.1.0**. The suite
has grown four groups since (`t00`, `t13`, `t14`, `t15`) and **has not been
re-run on the current code**; do that before quoting a number here.

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
| `t00` | the shell-level units (`tests/unit-shell.sh`): URL parsing and backend naming, presence as a set operation, batching with no ARG_MAX bomb, measured host detection, a report on every failure shape |
| `t13` | the report's `HOST` is the value `environment.json` recorded, verbatim, with the detection method beside it; the guarantee and its *does not prove* line are printed |
| `t14` | a failed isolation setup (a deliberately broken `ip` on `PATH`) yields `HARNESS_ERROR`, names the failed operations, does not blame the escrow, and is refused as a negative control |
| `t15` | `SOURCE_ORIGIN_INDEPENDENCE` end to end: the binary replica holds exactly what the approved tier supplied and nothing from staging, the three path sets partition the realised closure, `.drv` files are provided to nobody, and an insufficient tier yields `MODE_UNSUPPORTED` rather than a verdict about the escrow |
| `t16` | a remote escrow (a real HTTP binary cache) is materialised into a local proof replica before isolation, the evidence names both ends, and a `file://` escrow is still used directly |
| `t17` | every evidence file records the revision that produced it, whether the tree was dirty, and the hash of the manifest it judged |
| `t18` | proving one guarantee against an escrow preserved for another yields `MODE_UNSUPPORTED`, runs no build, names the mismatch rather than the escrow, and is refused as a negative control |
| `t19` | the **built package** reports a stamped revision, `revisionSource=flake`, the exact tested HEAD, and a clean source tree — the case a test against `$PWD/bin` cannot see |

Two checks earned their keep during development. `t06`'s content-identity check
caught a bug in the *test harness* that wrote through a hardlink and corrupted a
real narinfo in the escrow. And `t12` exists because the acceptance test really
did report `ORIGIN_INDEPENDENCE=PASS` with exit 0 while GitHub was reachable —
see below.

---

## Defects found in the first review, and what changed

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

## Defects found in the second review, and what changed

A second external review of v0.1.0. The three P0/P1 correctness defects are
fixed with a test each; the architectural findings changed the shape of the
tool.

| | defect | fix |
|---|---|---|
| **P0** | `HOST=Windows 11` was a **literal** in `lib/report.sh`, printed in every report on every machine — in a tool whose stated rule is that the report says what was demonstrated. It reached this file as a measured fact. | `nse_detect_host` measures it (WSL2 / virtualisation / container / not determined) and records *how it decided*; the report prints `HOST` and `HOST_DETECTED_BY` from that record. `NSE_HOST` lets an operator state one, labelled as operator-supplied. Tests `u05`, `t13`, and a source-wide grep (`u07`). |
| **P0** | With `set -e`, a `nse_prove` returning 1 killed the `escrow` command **before** the report was written. The report disappeared exactly when it was needed. | The pipeline accumulates stage failures and an `EXIT` trap writes the report on success, on failure, and on an abort inside a stage. Sections with no input print `NOT_RUN`; a run with no evidence at all prints `REPORT=INSUFFICIENT_STATE` rather than nothing. Tests `u08.1`–`u08.9`. |
| **P0** | The `ip link add dummy0` sequence ran unchecked under `set -uo pipefail`. On a kernel with no `dummy` module the interface never appeared and the run reported `FAIL` — *"build failed under origin blackout"* — blaming the escrow for a broken harness. | Every isolation operation is checked. A failure yields a distinct `HARNESS_ERROR` verdict, records which operations failed, and is refused by `--expect-fail`. Test `t14`. `DESIGN.md` §8, §11. |
| **P1** | `preserve` ran one `nix path-info` process **per store path** to decide staging-vs-host: 874 processes on the fixture. It then passed the whole path list on one `nix copy` command line — an `Argument list too long` waiting for a real closure. | The staging requisites query already answers the question, so the split is set arithmetic (`comm`) over lists Nix produced once. Copies go through `nse_nix_batched` (default 256 paths per invocation). Tests `u04.1`–`u04.5`. `DESIGN.md` §7. |
| **P1** | PROVE asserted `substituters == file://$NSE_CACHE`, so the escrow could only ever be a directory this tool created. An organisation's existing Attic / S3 / Artifactory cache could not be used at all. | The escrow is a URL: `--escrow-store` for writes, `--escrow-substituter` for reads, `--binary-replica` for the source-only mode. Presence, content identity and trust composition all go through backend-neutral `nix path-info`, so `file://` is the default rather than the architecture. Tests `u01`, `u02`, `t02.6`–`t02.9`. `DESIGN.md` §10. |
| **P1** | One name, `ORIGIN_INDEPENDENCE`, covered a claim that costs a copy of the whole realised closure. Running that on every dependency bump is a tax, not a gate. | Two named guarantees: `ESCROW_REPLAY` (default, unchanged strength) and `SOURCE_ORIGIN_INDEPENDENCE` (source material escrowed, approved binary tier allowed). Both write `proves` / `doesNotProve` strings into the evidence so the weak one cannot be quoted as the strong one. Test `t15`. `DESIGN.md` §12. |
| **P1** | `DESIGN.md` §3 claimed the SWH bridge was blocked by `postFetch` replay in general. That is too broad: SWH carries `nar-sha256` ExtIDs, so a directory can be looked up by the exact Nix identity, and replay never enters the picture on a hit. | §1 and §3 rewritten around *exact ExtID first, reconstruction on a miss*. The rule is now "replay is unnecessary exactly when the archive holds an object whose ExtID equals the expected Nix identity" rather than an enumeration of fetcher features. |
| **P1** | The manual flake-input restore proves `nix copy` works, not that a stock consumer with a `flake.lock` and a substituter gets its inputs. | `--native-input-restore` runs the primary path the way a consumer would; the manual copy stays as a diagnostic. Which one becomes the default is decided by experiment `E2`, not by argument. `DESIGN.md` §8a. |
| **P1** | The `dummy0` route-to-nowhere interface is probably unnecessary: Nix only auto-disables substitution when `substitute` is not an explicit override, and the test never set it. | `substitute = true` is now set explicitly. The interface is still created by default — reading `src/nix/main.cc` is not this repo's standard of evidence — and `tests/experiments.sh` `E1` is the run that decides whether it goes. |

Two of these were fixed by argument alone and are therefore **not yet
demonstrated**: `E1` and `E2` are hypotheses with an experiment attached, not
results. See KNOWN_GAPS 17.

---

## Defects found in the third review, and what changed

The second change set was reviewed again before merge, and it had found its own
new problems: making storage abstract exposed that the *network* model had not
moved with it, and naming a weaker guarantee exposed that its binary-tier model
claimed more than the data supported.

| | defect | fix |
|---|---|---|
| **P0** | `--escrow-store` / `--escrow-substituter` accepted any Nix store URL, and PROVE then configured that URL as `substituters` **inside a namespace with no route**. A remote escrow is exactly as unreachable in there as GitHub is, so "the escrow was the only substituter" described a store the test could not reach. "First-class target" was a claim about storage stated as a claim about acceptance. | A non-local escrow is materialised into a local **proof replica** before isolation, and the test replays from that. The evidence records both ends and which was used (`replaySource.durableEscrow`, `escrowUsedByTest`, `escrowMode`, `escrowObjects`), and the docs now separate storage target from acceptance target. Test `t16` runs it against a real HTTP binary cache. `DESIGN.md` §13. |
| **P0** | `SOURCE_ORIGIN_INDEPENDENCE` filled its binary replica with `closure − sources` copied out of the **staging store**. Staging builds locally whatever it cannot substitute, so an object this machine produced was served to the test as though the approved cache had it — and the evidence read "works given the approved binary tier" about a tier that may never have held it. A fidelity problem, not a trust problem. | The replica is filled **from `--binary-tier` and from nothing else**. `.drv` paths are asked of nobody (the test instantiates them). What the tier lacks is supplied by nobody, so anything the build needs from that set it has to build — correct, and a stronger test. No signature-based inference is used: the version of this fix that shipped in the third change set did make one, and the fourth-review entry below records why it was wrong and removed it. `MODE_UNSUPPORTED` is reserved for a guarantee mismatch, as that entry describes. Tests `t15.11`–`t15.16`. `DESIGN.md` §12. |
| **P1** | `experiments.sh` mapped `FAIL → REFUTED` unconditionally. With a broken escrow every variant fails, so it would have written a confident `dummyInterfaceStillNeeded: true` that no run supported — the most confident wrong answer this repository could produce. | `E0` is a baseline: if it is not green, `E1`–`E3` are not run and are recorded `INCONCLUSIVE` with the reason. `E3` is `INCONCLUSIVE` unless `E1` and `E2` are each CONFIRMED alone. `HARNESS_ERROR` / `MODE_UNSUPPORTED` are inconclusive, never refutations. The conclusion fields are `null` when unknown instead of guessing. The rules are a pure function, unit-tested by `u10.1`–`u10.14`. |
| **P1** | Under `SOURCE_ORIGIN_INDEPENDENCE` the post-build presence check still carried the `ESCROW_REPLAY` argument — "the store was empty and nothing was reachable, so it came from the escrow". With two substituters configured, and an approved cache that may well carry source FODs, that no longer follows. | The escrow is asked directly, before isolation, whether it holds every plan-required source; the count is recorded as `sourcesInEscrowBeforeIsolation` and a shortfall is a `FAIL`. This also makes `test-origin-independence` sound standalone instead of quietly depending on someone having run `verify` first. Test `t15.9`. `DESIGN.md` §11. |
| **P1** | Nothing bound a result to the code that produced it. `E1 = CONFIRMED` two commits later is a rumour. | Every evidence file carries `provenance`: commit, dirty flag (untracked files count), Nix version, and the SHA-256 of the manifest and closure it judged. The report prints `TOOL_COMMIT`. Tests `u11`, `t17`. `DESIGN.md` §14. |

---

## Defects found in the fourth review, and what changed

Three findings, two of them about causal claims the previous change set had
made without the data to support them.

| | defect | fix |
|---|---|---|
| **P0** | Provenance asked `git` at runtime, and the fix for it being empty was to add `git` to `runtimeDeps`. That treats the symptom: `NSE_ROOT` for an installed tool is a `/nix/store` path, the `src` filter deliberately drops `.git`, and an immutable store path has no working tree. Every `nix run` would have recorded a null revision — shipping a `git` binary to read a repository that was never packaged. | The revision is stamped in at build time from the flake (`self.rev or self.dirtyRev`) into `$out/share/nix-source-escrow/build-info.json`; the runtime `git` query survives only as the dev-checkout fallback, and `revisionSource` says which one answered. `workingTreeDirty` is `null` for a packaged build, because the concept does not apply there. Test `t19` asserts it through the **built** package — a test against `$PWD/bin` passes for the broken version. `DESIGN.md` §14. |
| **P0** | `SOURCE_ORIGIN_INDEPENDENCE` read a cache signature on a staging path as proof the path had been *substituted*, and declared the mode unavailable when the approved tier lacked such a path. A signature is not proof of substitution (Nix signs locally built paths when `secret-key-files` is set), and "the previous staging run chose to download X" says nothing about whether X can be built — the mode already permits a rebuild for everything the tier does not hold. | The heuristic is gone entirely. The tier supplies what it has; everything else is provided to nobody and the acceptance build is the judge of whether it can be produced. `MODE_UNSUPPORTED` is now reserved for a claim the harness cannot *model*: an escrow preserved for one guarantee and proven against another, which test `t18` triggers deterministically. Tests `t15.11`–`t15.16`. `DESIGN.md` §12. |
| **P1** | `nix copy` copies *closures*, so `escrowObjects: 53` reported the size of the **request**, not the size of the result — and under `SOURCE_ORIGIN_INDEPENDENCE` a closure copy could quietly place a `notProvidedPaths` object next to the build, making "the test rebuilt it" false. | The stores the test will use are listed and counted: `objectsRequested`, `objectsReachableByTest`, `objectsArrivedAsClosure`, and `notProvidedReachableByTest`. A non-zero last field is a `FAIL` with that reason. Tests `t15.17`–`t15.18`. `DESIGN.md` §13. |
| **P1** | Reading the stamped dirty flag with `jq '.workingTreeDirty // null'` returned `null` for a **clean** build: jq's `//` treats `false` as absent — the exact operator this repository warns about in `DESIGN.md` §6, walked into by the function that was supposed to make results trustworthy. | `has()` instead. Unit test `u11.4d` fails if it comes back. |

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
   Mirroring them is `nixpkgs-swh`'s job. This is unchanged by the guarantee
   modes: `SOURCE_ORIGIN_INDEPENDENCE` narrows what is *escrowed*, not what is
   *discovered*.
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

8. **No Software Heritage bridge.** The recovery model — exact `nar-sha256` /
   `checksum-*` ExtID lookup first, revision/origin recovery next,
   reconstruction only on a miss — is researched and written down
   (`DESIGN.md` §1) but **not implemented and not validated**. Not one SWH
   request has ever been made from this code. No claim of SWH recoverability
   is made here.
9. **`postFetch` replay is unsolved** (`DESIGN.md` §3). Recovering the upstream
   artefact from any archive does not reconstruct a `fetchzip`-class output; you
   must replay unpack + `stripRoot` + the caller's shell in the same `stdenv`
   and land on the same NAR hash. It is the *fallback* path for item 8, not a
   precondition for it — an earlier version of this list said otherwise, and
   `DESIGN.md` §3 now explains why that was too broad.
10. `RECOVER` in v0.1 means "the origin, or the escrow". There is no repair path
    for the two `EXTERNAL_RECOVERY` sources beyond the escrow itself and the
    manual `nix-store --add-fixed` procedure nixpkgs documents.

**Mechanism**

11. The acceptance test needs unprivileged user namespaces. It will not run
    where those are disabled.
12. The test still carries a **behavioural workaround for Nix 2.34.7**: a dummy
    interface with a route to nowhere, because Nix disables all substituters —
    `file://` ones included — when it decides there is no Internet
    (`DESIGN.md` §8). `substitute = true` is now set explicitly and should make
    it unnecessary, but that is a reading of the Nix sources, not a run. The
    workaround does not weaken the isolation — the by-address probes prove it,
    and `t12` proves the verdict does not depend on trusting it.
13. Trust results are measured on Nix 2.34.7 with this daemon configuration.
    `t09` will fail loudly if that changes, which is the intent.
14. The escrow is addressed by URL. `t16` exercises the non-file path against a
    real HTTP binary cache, so the presence/metadata/materialisation code has
    been run for something other than a directory — but **`s3://`, `ssh-ng://`
    and a real Attic or Artifactory deployment have not**, and neither has any
    credentialed access (`NSE_EXTRA_NIX_CONFIG` is the hook, untested). There
    is still no replication, GC policy or access control.
15. `preserve` requires network — it is the step that fetches from origins while
    they still exist. Only `verify` and the acceptance test are offline.
16. The acceptance test proves the *escrow* served the sources by elimination
    (empty store, no route, escrow-only substituters). It does not parse
    per-object provenance out of the Nix log.

**The second guarantee**

17. **`E1` and `E2` are unrun experiments, not results.** `substitute = true`
    should retire the dummy interface, and Nix should substitute locked flake
    inputs without our manual copy. Both are read out of the Nix sources; both
    default to the old behaviour until `tests/experiments.sh` says otherwise on
    a real Nix.
18. `SOURCE_ORIGIN_INDEPENDENCE` models "your approved binary cache is still
    up" with a **local replica filled from that cache**, because the harness
    cuts all egress rather than filtering it selectively. The replica's
    *contents* are now faithful; its *reachability* is still simulated. Same
    missing piece as gap 20: a version that keeps origins blocked while the
    real approved cache stays reachable needs selective egress.
20. **The acceptance test cannot reach a remote escrow, by construction.** A
    non-local escrow is materialised into a local proof replica before
    isolation (`DESIGN.md` §13), which establishes that the durable store held
    every object and that the set replays offline — and establishes nothing
    about that store being reachable during a blackout. A selective harness
    (`nftables`/`pasta` allowlist permitting only the escrow endpoint) would
    prove the stronger thing and is not built.
21. `MODE_UNSUPPORTED` has exactly one trigger: an escrow preserved for one
    guarantee and proven against another. Whether the acceptance build can
    actually produce everything `closure.notProvidedPaths` names is left to the
    build, and a failure there surfaces as an ordinary `FAIL` — with
    `notProvidedPaths` in the evidence as the first place to look. That is
    deliberate: predicting buildability from a signature was the previous
    version of this gap and it was wrong.
22. The **contents** of the binary replica are now faithful to the named tier;
    its **reachability** is still simulated, and the replay audit only measures
    `file://` stores. Both are honest today only because a materialised proof
    replica is always local — a future non-file replay target would need the
    audit extended rather than assumed.
19. The change sets answering the second, third and fourth reviews have been
    **exercised only by `tests/unit-shell.sh`** (69 checks, all passing, no Nix
    required). The Nix-dependent suite — including the new `t13`–`t19` — has
    not been run on this code, because the machine it was written on has no
    Nix. Treat the report block above as a v0.1.0 record until you re-run it.

---

## What to do next

In the order the value arrives. The first item is not optional: everything
below it is written but unmeasured.

1. **Re-run everything on a machine with Nix.** `./tests/run-tests.sh`, then
   `./tests/experiments.sh`, then `nix build .#nix-source-escrow` and
   `./result/bin/nix-source-escrow --help`, then replace the report block in
   this file with the new `escrow/evidence/report.txt`. Until then this file
   documents v0.1.0 and four change sets, not a result. That acceptance rule —
   `provenance.toolRevision` names the tested HEAD and `workingTreeDirty` is
   `false` — is now asserted by `t19.6` and `t19.7` rather than left to a
   reviewer, so run the suite on a **committed, clean** tree: a result measured
   on a dirty tree is a result about nothing in particular. Do not use
   `NSE_TEST_REUSE=1` for the first official run; inherit no staging or escrow
   from the previous semantics. Watch `t15.18`
   (`notProvidedReachableByTest`) in particular: if it is non-zero, a closure
   copy is reaching further than the accounting claims and the "rebuilt inside
   the test" wording needs revisiting, not the assertion.
2. **Retire the two workarounds the experiments clear.** If `E1` is CONFIRMED,
   delete the dummy interface and `DESIGN.md` §8. If `E2` is CONFIRMED, make
   `--native-input-restore` the default and demote the manual copy to a
   diagnostic. If either is REFUTED, write down *why* — that is a more
   interesting finding than the fix. If `E0` is not green, fix that first and
   read nothing else from that run.
3. **Run the escrow against a real remote backend.** Attic or an S3 bucket,
   end to end, with credentials, so gap 14 stops being an HTTP-server test and
   becomes deployment evidence.
4. **Selective egress for the acceptance harness** (gaps 18 and 20). An
   allowlist that permits only the escrow endpoint turns two simulated
   properties into measured ones: a remote escrow reachable during the
   blackout, and an approved binary tier that is genuinely third-party.
5. **Make the cheap guarantee the CI gate it was designed to be.** Renovate /
   `update-flake-lock` integration: `preserve → verify →
   test-origin-independence --guarantee source-origin-independence` as a
   required check on the update PR, sharing one staging store, so a dependency
   bump cannot merge until its sources are in escrow — without copying the
   world on every bump.
6. **Then the Software Heritage repair layer**, in the order §1 now describes:
   exact `nar-sha256` / `checksum-*` ExtID hit first, revision/origin recovery
   next, reconstruction (Disarchive-style for flat artefacts, `postFetch`
   replay for the rest) only where the first two miss. An archival *check* per
   source — the equivalent of `guix lint -c archival` — is the cheap half and
   is worth doing before the recovery half.
7. Flat-`fetchurl` hashed-mirror layer, reusing the `copy-tarballs.pl` key
   scheme, for sharing tarballs between organisations.
8. Incremental staging: diff the manifest against the escrow and fetch only
   what is new. `--staging-dir` already lets several escrows share one warm
   staging store, which is the cheap half of this.
9. Explicit IFD / manual-escrow policy, with a real IFD project as the fixture.
10. `FULL_AIRGAP_REBUILD` as a separate, separately-named guarantee — the third
    row of `DESIGN.md` §12, and the one that needs signing per §4.
