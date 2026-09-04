# EVIDENCE

Facts from an actual run, not a summary of intent. Reproduce with:

```bash
nix develop
nix-source-escrow escrow "path:$PWD/fixture#default"
```

> **First real execution: 2026-09-03, GitHub Actions, commit `a471627`.**
> A matrix over Nix 2.34.7 and 2.24.9. It is a **pre-fix diagnostic bundle**,
> not canonical evidence: the main suite was red (106/22 on 2.34.7),
> `SOURCE_ORIGIN_INDEPENDENCE` never completed, and `t16` never reached its
> acceptance step. What it *did* establish, and what remains true:
>
> | | |
> |---|---|
> | `ESCROW_REPLAY` on Nix 2.34.7 | **PASS**, end to end |
> | replay audit | 874 requested, 874 reachable, `notProvidedReachableByTest = 0` |
> | discovery on 2.34.7 | 165 sources / 163 covered / 2 external-recovery |
> | host autodetection | worked: `virtualised (microsoft)` via `systemd-detect-virt` |
> | provenance | exact tested HEAD, `workingTreeDirty = false`, `revisionSource = flake` on the packaged build |
> | **E0 / E1 / E2 / E3** | **BASELINE_OK / CONFIRMED / CONFIRMED / CONFIRMED** |
> | Nix 2.24.9 | `nix derivation show` emits a flat map; discovery read zero and reported complete |
> | trust metadata | TSV tab-collapse defect, reproduced |
> | source mode | harness crash (`E2BIG` via an exported `$out`), not a guarantee failure |
> | remote escrow (`t16`) | **not verified** — the test server's port handshake was broken, so the acceptance steps never ran |
>
> Four defects came out of it, three of them the same mistake in different
> clothes (`DESIGN.md` §15). All four are now fixed with a regression test
> each. **A fresh frozen run is required before anything here becomes canonical
> evidence.**
>
> **Runs since, on the same fixture and the same matrix.** Each is a cold run
> with no `NSE_TEST_REUSE`. `ESCROW_REPLAY` passes on **both** Nix versions in
> every one of them, with an identical `closureSha256`, and
> `E0/E1/E2/E3 = BASELINE_OK / CONFIRMED / CONFIRMED / CONFIRMED` on both.
>
> | run | 2.34.7 | 2.24.9 | what it found |
> |---|---|---|---|
> | 6 | 117 / 18 | 108 / 27 | the presence P0: `"path": null` read as present, `nix copy` then died fetching an object no cache could hold |
> | 7 | died in `t20` | died in `t20` | `find … \| head` + `pipefail` + `set -e`: the new test aborted the suite before it could print a result |
> | 8 | **all steps green** | 135 / 9 | first fully green leg. All nine remaining failures are one finding: the 2.24.9 derivation-attribute gap |
> | 9 | all steps green | 135 / 9 | the probe added to diagnose that finding ran `nix derivation show` without `-r` and measured its own invocation |
> | 10 | all steps green | 135 / 9 | the probe, fixed, named the outliers: 17 `__structuredAttrs` derivations carrying their attributes in `env.__json` |
> | **11** | **all steps green** | **all steps green** | **144 / 0 and 144 / 0.** The canonical result below |
> | 15 | 143 / 1 | 143 / 1 | the **removal** run (`913df97`). Every pre-registered observable unchanged from run 11, `closureSha256` included. The one failure is `t07.9`, which asserted `.restoreExit == 0` — the exit code of a `nix copy` the default path never ran. `DESIGN.md` §17b |
>> | 17 | 144 / 1 | 144 / 1 | the repair (`102d5a1`). Observables still unchanged. The repaired `t07.9a` asserted all four flake inputs are in the test store; the answer is **2 of 4**, and 2 of 4 is Nix being correct. `DESIGN.md` §17c |
>
> The nine are `t01.3`, `t01.4`, `t01.7` and all of `t10` — every one an
> assertion about an origin URL, a hash mode or a `postFetch`. On 2.24.9
> discovery reports `COVERED=146 / EXTERNAL_RECOVERY=19 / WITH_POSTFETCH=0`
> against `163 / 2 / 3` on 2.34.7, for a byte-identical closure and the same 638
> derivations and 165 fixed-output sources. It is a defect in what the evidence
> says about **origins**, not in what the escrow **holds**.
>
> **Run 10 measured it and it is now fixed.** Two causes. The schemas disagree
> about the map KEY as well as the envelope, so `drvPath` was
> `/nix/store//nix/store/…drv` on every 2.24.9 run. And the 17 sources are
> `__structuredAttrs` derivations, whose attributes are a parsed
> `structuredAttrs` object on 2.34.7 and the JSON **string** `env.__json` on
> 2.24.9 — 17 of them, plus the 2 real minimal-bootstrap sources, is the 19.
> Both fixed, with `u12.5a`/`u12.5b` and `u16.1`–`u16.7`. `DESIGN.md` §15a has
> the route, which is worth more than the fix: the right hypothesis was told on
> no evidence, then **refuted** on no evidence by a probe that sampled the first
> two fixed-output derivations in the document — both plain `fetchurl`, both
> identical on the two versions. Naming the outliers settled in one run what
> counting them had not settled in three.
>
> **Run 11 (`783bc5a`) is green on both Nix versions, every step**, and its
> report is the canonical Result section below. Three commit identities are
> kept apart on purpose, here and in the machine-readable `evidence-runs.json`:
>
> ```
> run_11.measured_commit      = 783bc5a   the tree the suite actually executed
> run_11.evidence_recorded_by = d72dbbf   documentation only (EVIDENCE.md, 1 file),
>                                         necessarily later, and NOT itself measured
> review_reference_commit     = 6a6687c   the frozen review subject; has never moved
> ```
>
> Collapsing those three into "current HEAD" is how a measurement gets attached
> to a state that was never run, and this file has already paid for one
> provenance shortcut. The **v0.1.0** block that
> follows it is kept as history, not as evidence: it predates the second review
> and carries, in plain sight on its third line, the `HOST=Windows 11` literal
> this file used to present as a measured fact.

---

## Result (canonical): run 11, commit `783bc5a`, 2026-09-04

GitHub Actions, `ubuntu-latest`, a matrix over Nix **2.34.7** and **2.24.9**.
Cold: no `NSE_TEST_REUSE`, `escrow/` created from nothing, staging store empty,
every artefact re-fetched from its origin before being preserved. Every step of
both matrix legs is green.

| | 2.34.7 | 2.24.9 |
|---|---|---|
| `tests/unit-shell.sh` | 102 / 0 | 102 / 0 |
| `nix flake check` (shellcheck) | pass | pass |
| `tests/run-tests.sh` (`t00`–`t20`) | **144 / 0** | **144 / 0** |
| `E0 / E1 / E2 / E3` | BASELINE_OK / CONFIRMED / CONFIRMED / CONFIRMED | same |
| `closureSha256` | `9243083e…f8ec` | **the same** |

The two versions now agree on every discovery number as well
(`COVERED=163`, `EXTERNAL_RECOVERY=2`, `WITH_POSTFETCH=3`, `ON_KNOWN_FORGE=38`),
which they did not before `783bc5a`. The only difference either report shows is
the one that is a fact about Nix: `DERIVATION_DOCUMENT=envelope v4` against
`flat-map vabsent`, both over the same 638 derivations.

The block below is the 2.34.7 leg's `escrow/evidence/report.txt` verbatim, with
the runner's repository path shortened to `$PWD`. The 2.24.9 leg's differs only
in `NIX_VERSION`, `DERIVATION_DOCUMENT`, `CLIENT_IS_TRUSTED_USER=1` (older Nix
prints `1`, not `true`) and the DNS addresses in the probe lines.
Machine-readable originals are in the run's `evidence` artifact.

```text
ENVIRONMENT
NIX_VERSION=2.34.7
SYSTEM=x86_64-linux
HOST=virtualised (microsoft)
HOST_DETECTED_BY=systemd-detect-virt
EXECUTION_ENV=Ubuntu 24.04.4 LTS
KERNEL=Linux 6.17.0-1022-azure
CLIENT_IS_TRUSTED_USER=true
AMBIENT_REQUIRE_SIGS=true
AMBIENT_HASHED_MIRRORS=(unset)
TOOL_COMMIT=783bc5a9c8ac [git-checkout] (clean)

DISCOVERY
INSTALLABLE=path:$PWD/fixture#default
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
DERIVATION_DOCUMENT=envelope v4, 638 derivations
IFD_DETECTED=absent
EVAL_TIME_FETCH_STATIC_ENUMERATION=impossible
EVAL_TIME_FETCH_OFFLINE_PROBE=clean
ESCROW_DISCOVERY_COMPLETE=PASS
  note: eval-time builtins.fetch* are unenumerable statically, but evaluation succeeded offline with an empty cache under network isolation, so none needed the network
  note: 2 fixed-output source(s) have no origin URL at all (nixpkgs minimal-bootstrap); they can never be re-fetched upstream, only restored from a cache/escrow

ESCROW
GUARANTEE=escrow-replay
BACKEND=local-file-binary-cache
STORE_URL=file://$PWD/escrow/cache
SUBSTITUTER_URL=file://$PWD/escrow/cache
BINARY_REPLICA_URL=(none: the escrow holds the whole closure)
APPROVED_BINARY_TIER=(none)
COMPRESSION=zstd
FLAKE_INPUTS_PRESERVED=4/4
SOURCES_REQUIRED_BY_PLAN=4
SOURCES_PRESERVED=4
SOURCES_MISSING=0
SOURCES_DISCOVERED_NOT_REQUIRED_BY_PLAN=161
OBJECTS_REALISED=874
  IN_ESCROW=874
  IN_BINARY_REPLICA=0
  PROVIDED_TO_NOBODY=0 (the test instantiates or rebuilds these)
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
GUARANTEE=ESCROW_REPLAY
  proves: the accepted build completes with every dependency origin and every third-party binary cache unreachable, from an empty store, using only the escrow
  does not prove: FULL_AIRGAP_REBUILD: the escrow holds prebuilt binaries that came from cache.nixos.org, so this does not show the graph can be rebuilt from source alone
NETWORK_ISOLATION=user+network+mount namespace (unshare -Ur --net --mount)
ISOLATION_MODE=namespaces
ISOLATION_SETUP=ok
DUMMY_INTERFACE=absent
NSS_ISOLATION=full
ORIGIN_HOSTS_PROVEN_UNREACHABLE=github.com,codeload.github.com,raw.githubusercontent.com,gitlab.com,ftp.gnu.org
ORIGIN_HOSTS_REACHABLE=none
CACHE_NIXOS_ORG_ALLOWED=false
DURABLE_ESCROW=file://$PWD/escrow/cache
REPLAYED_FROM=file://$PWD/escrow/cache (direct, 874 objects)
MODE_SUPPORTED=true
REPLAY_OBJECTS_REQUESTED=874
  REACHABLE_BY_TEST=874  ARRIVED_AS_CLOSURE=0
  NOT_PROVIDED_BUT_REACHABLE=0
SOURCES_IN_ESCROW_BEFORE_ISOLATION=4/4
SUBSTITUTERS_ONLY_ESCROW=true
SUBSTITUTERS_AS_CONFIGURED=true
EFFECTIVE_SUBSTITUTERS=file://$PWD/escrow/cache
FLAKE_INPUT_RESTORE=native
PROBE_METHOD=curl by name and by address pre-resolved outside the namespace
OFFLINE_EVAL_PROBE=clean
HTTP_FETCHES_IN_BUILD_LOG=0
REQUIRED_SOURCES_PRESENT_AFTER_BUILD=4/4
OUTPUT_PATH=/nix/store/kfmaahsrnil10qp66f3dnisv557bpa3a-escrow-fixture-0.1
OUTPUT_MATCHES_MANIFEST=true

ORIGIN_INDEPENDENCE=PASS
  probe github.com [140.82.112.3]: byName=false (curl 6), byAddress=false (curl 7)
  probe codeload.github.com [140.82.114.9]: byName=false (curl 6), byAddress=false (curl 7)
  probe raw.githubusercontent.com [185.199.111.133]: byName=false (curl 6), byAddress=false (curl 7)
  probe gitlab.com [172.65.251.78]: byName=false (curl 6), byAddress=false (curl 7)
  probe ftp.gnu.org [209.51.188.20]: byName=false (curl 6), byAddress=false (curl 7)
  probe cache.nixos.org [146.75.29.91]: byName=false (curl 6), byAddress=false (curl 7)
```

---

The v0.1.0 run below started by deleting `escrow/` entirely, so the staging
store was cold and every artefact was re-fetched from its origin before being
preserved. It is kept for the record of what was measured then.

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

`./tests/unit-shell.sh` — **102/102 passed**, on both Nix versions in run 11
(it needs no Nix; it runs on the matrix anyway because it is free).

`nix develop -c ./tests/run-tests.sh` — **144/144 passed on Nix 2.34.7 and
144/144 on Nix 2.24.9**, cold, in run 11 (`783bc5a`). `t20` joined the suite in
run 8 and passes on both.

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
| `t20` | a binary tier that serves a `narinfo` for a `.nar` it does not have yields `BINARY_TIER_ERROR` and names the object, rather than reclassifying it as "the tier does not have it, let the build rebuild it" |

Since the removal commit, `t07`, `t15` and `t16` also carry what `E3` used to
measure: with the dummy interface and the manual input restore deleted, the
default acceptance path *is* the configuration those experiments validated, and
there is no flag left to disable it.

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

## Defects found in the fifth review, and what changed

These came out of the **first real execution** of the suite (GitHub Actions,
Nix 2.34.7 and 2.24.9). Four of the five earlier rounds were reviews of code.
This one is a review of measurements, and it found the thing every previous
round had walked past: the presence check at the bottom of everything was
answering "yes" to every question it was ever asked.

| | defect | fix |
|---|---|---|
| **P0** | `nse_store_present` read `nix path-info --json` with `keys[]`. Nix does **not** omit a path it cannot find and does **not** fail the command: it emits `"<path>": null` and exits `0`. That is `InvalidPath` → `jsonObject = nullptr` with the key still added, in **both** measured versions (2.24.9 and 2.34.7). So `ABSENT → "path": null → keys[] → PRESENT`, and 227 tier candidates went in and 227 "supplied" came out — including a store path this machine had built ten minutes earlier that no public cache could hold. `nix copy` then tried to fetch it and the run died. Structural presence read as semantic presence: the same defect family as every other entry in this file, sitting under all of them. | `nse_pathinfo_present_keys` keeps only entries whose value is non-null, understands both the object and the array shape, and **errors** on any third shape rather than returning nothing. Every remote-backend presence query goes through it, not only the binary tier; `file://` was never affected because it stats a narinfo. Unit tests `u15.1`–`u15.7`. |
| **P0** | The binary tier reported one number where there were two facts. "The tier says it holds *N*" and "*N* objects arrived" were the same field, so a tier that claims a path and then cannot serve it was indistinguishable from a tier that never claimed it — and the difference is the whole of `SOURCE_ORIGIN_INDEPENDENCE`. A per-path fallback would have hidden this behind 227 process spawns instead of fixing it. | Probe and materialisation are separate stages with separate evidence: `candidates`, `present` (claimed), `materializationRequested`, `materializedRoots` (**re-queried from the destination**, not assumed from the request), `claimedButNotMaterialized`, `notProvided`. A copy failure is **classified**, never relabelled: if the source still claims to hold a path it would not give up, that is `BINARY_TIER_ERROR` and the run dies. An ambiguous failure is never quietly promoted to "unavailable, so the test may rebuild it". Test `t20` runs it against an HTTP tier that keeps the `.narinfo` and deletes the `.nar`. |
| **P1** | `nse_store_pathinfo` — the metadata reader that feeds trust classification — had the identical null blindness in its map form, so an absent path could enter the sample set as an object with no `ca` and no `sigs`. | Null entries are dropped in both shapes before the map is built. |
| **P1** | `u14.3` was a **false pass**. It exported a 300 KB `$out` and asserted the query returned `0` — but a single 300 KB environment string exceeds `MAX_ARG_STRLEN`, so *every* `exec` in that subshell fails, `jq` included. It only ever went green because the old parser ignored `jq`'s exit status. The instant the parser began failing closed, the test went red: a test that could only pass while the code under it was fail-open, and it would have argued for putting the fail-open back. | Rewritten to put the bulk where the bug put it — in the store's **answer**, with `$out` exported at the size `nix develop` actually exports it. `u14.4` fails if the internal name is ever exported again; `u14.5` checks all 4000 paths are read back, so the test cannot pass by returning nothing. |

The first two are the reason `a471627` stays labelled a pre-fix diagnostic
bundle and is not promoted to canonical evidence: its `binaryTier` numbers were
produced by the parser described in the first row.

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
19. Closed. The Nix-dependent suite has been run cold on both Nix versions and
    is 144/0 on each (run 11, `783bc5a`), and the canonical Result section is
    that run's report rather than the v0.1.0 one.

---

## What to do next

In the order the value arrives.

1. ~~**Re-run everything on a machine with Nix.**~~ **Done** — run 11
   (`783bc5a`), cold, on Nix 2.34.7 and 2.24.9, committed clean tree, 144/0 on
   each. `t15.18` (`notProvidedReachableByTest`) is `0`, so the closure copy is
   not reaching further than the accounting claims. The eleven runs it took are
   the run table at the top of this file, and the five defects they surfaced are
   `DESIGN.md` §15 and §15a.
2. ~~**Retire the two workarounds the experiments cleared.**~~ **Done.** The
   dummy interface and the manual flake-input restore are deleted, not demoted:
   `E1`/`E2`/`E3` were CONFIRMED on both Nix versions in every run from 6 to 11
   with `E0` green each time, and a diagnostic nobody runs is indistinguishable
   from dead code. `E0`–`E3` are retired with them and their final values are
   frozen in `evidence-runs.json`; the rules for reading any future experiment
   survive in `lib/experiment.sh`. `DESIGN.md` §8, §8a, §17 and §17a — the last
   of which records that the pre-registration's own acceptance criterion was
   unsatisfiable by the change it pre-registered, found and corrected before the
   judging run rather than after it. The `measured on: unknown` defect is fixed
   separately (`u17`).
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
