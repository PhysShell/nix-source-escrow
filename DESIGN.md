# DESIGN

Only decisions that were expensive to get right, or that a reader would
otherwise get wrong. Everything about *this tool's behaviour* was measured on
the machine described in `EVIDENCE.md`, not assumed.

One kind of statement here is not a measurement, and it is labelled where it
appears: figures quoted from upstream projects (§1). There used to be a second
kind — hypotheses read out of the Nix sources and not yet run — which shipped
with an experiment rather than a conclusion. Those two hypotheses have since
been run to a conclusion and the mechanisms they were about have been deleted;
§8, §8a and §17a are what is left of them.

---

## 1. Software Heritage is a repair backend, not a substituter

Two claims, and only the first was right in the first draft of this file.

**SWH is not a substituter.** There is no `narinfo` endpoint, no store-path
protocol, and the vault cook that materialises a directory is asynchronous and
rate-limited. Nothing about it fits inside `substituters`. It is a *repair*
path: it runs when the escrow has a hole, verifies its result against the
expected Nix hash, writes that result **into** the escrow, and is then never
consulted again. Subsequent builds must not depend on it.

**SWH stores only the upstream representation — wrong, and this file said it.**
Software Heritage carries `ExtID`s that map a foreign identity onto an archived
object, and the relevant ones here are `nar-sha256` (the Nix/Guix recursive-NAR
identity of a directory tree) alongside `checksum-sha256` / `checksum-sha512`
for flat artefacts. Guix has driven git-source fallback through NAR-hash lookup
since early 2024. So for a large class of objects the archive can be asked the
*exact* question we care about — "do you hold the tree whose NAR hash is X?" —
and replay never enters the picture.

That changes the recovery algorithm. Exact identity first, reconstruction only
as a fallback:

```
expected Nix identity (NAR hash, or flat sha256/sha512)
      |
      +-- GET /api/1/extid/<type>/<hash>/          exact ExtID lookup
      |      hit -> cook -> download -> re-verify the expected hash -> escrow
      |
      +-- miss: no object with this identity is archived
             |
             +-- origin/revision recovery (swh:1:rev, swh:1:dir from a VCS origin)
             +-- Disarchive-style tarball reconstruction for flat artefacts
             +-- replay: unpack + stripRoot + the caller's postFetch, in the
                 same stdenv, landing on the same NAR hash          (see §3)
```

The correct statement of when replay is needed is therefore **not** a list of
fetcher features. It is one condition:

> Replay is unnecessary exactly when the archive already holds an object whose
> ExtID equals the expected Nix identity. How that object came to be archived
> is somebody else's problem.

That is both stronger and shorter than enumerating `postFetch`, `stripRoot =
false` and submodules as "the cases that need replay" — an enumeration that is
a guess about coverage dressed as a rule.

**What this repository claims about SWH: nothing.** The algorithm above is
researched and written down. It is **not implemented and not validated here**,
and no SWH lookup has ever run from this code. It is the post-v0.1 repair
layer, not a dependency.

**Numbers quoted from upstream, and how to read them.** The Guix/SWH
integration is far ahead of anything Nix has, and it is tempting to quote its
coverage figures as if they settled the question. They do not, and the way they
get misquoted is worth writing down:

| figure | what it actually says |
|---|---|
| *Preservation of Guix*, overall: ~85% stored, ~9% missing, ~6% unknown | the whole dataset. Git-origin sources score far higher (~97%) than the aggregate |
| a ~94% "stored" line in the same report | one weekly snapshot, not historical coverage of everything Guix has ever referenced |
| Disarchive "97.3% of 41,521 tarballs" | successfully **disassembled** — that is a property of the metadata step, not a promise that 97.3% are recoverable end to end today |
| SWH API rate limits | published per-IP limits change; the anonymous tier is small and the authenticated tier is larger. Treat any number as current-at-time-of-reading |

Every row above is **cited, not measured in this repository.** The rule this
repo applies to its own results applies to the ones it borrows: a figure with
the wrong caption is worse than no figure.

The honest comparison is not "Guix has 94% and we have an escrow". It is:

```
Guix + SWH               an external preservation service plus automatic
                         recovery, with best-effort coverage you do not control

nix-source-escrow        operator-controlled preservation plus an acceptance
                         proof, with coverage you can point at and a test that
                         goes red when it is wrong
```

Different trust and availability models. The second is not a replacement for
the first, and the first is not a reason to skip the second.

---

## 2. Flat hash vs recursive/NAR hash

Two genuinely different objects, and the escrow has to keep them apart.

| | `outputHashMode = "flat"` | `outputHashMode = "recursive"` (`method: "nar"`) |
|---|---|---|
| hash covers | the downloaded bytes, verbatim | the NAR serialisation of a directory tree |
| produced by | `fetchurl` | `fetchzip`, `fetchFromGitHub`, `fetchgit`, flake inputs |
| upstream artefact recoverable? | yes, it *is* the artefact | not directly |
| hashed-mirror layout applies? | yes | no |

`copy-tarballs.pl` and Nix's `hashed-mirrors` only ever addressed the flat case:
the mirror is keyed by `sha512/<hex>` (with `sha256/...` redirects) and serves
the original file. That is useful and cheap, but it covers **159 of 164** sources
in our fixture graph by count while leaving the interesting ones uncovered.

v0.1 deliberately does **not** implement a hashed mirror. A store-path escrow
covers both modes with one mechanism (`nix copy` to a `file://` binary cache),
and adding a second, flat-only layer would buy nothing for the acceptance test.
It stays on the post-v0.1 list because it is the right shape for sharing flat
tarballs *between* organisations, which store paths are not.

---

## 3. The `postFetch` problem

**`upstream source tree != final fixed-output result`.** Concretely, in
`pkgs/build-support/fetchzip/default.nix`:

```nix
recursiveHash = true;
downloadToTemp = true;
postFetch = ''
  unpackDir="$TMPDIR/unpack"
  ...
  unpackFile "$renamed"
  ...            # if stripRoot: move the single top-level dir up one level
  ${postFetch}   # arbitrary caller-supplied shell
'';
```

`fetchFromGitHub` (without submodules) is `fetchzip`, which is `fetchurl` with
that `postFetch`. So for a `fetchFromGitHub` source the recorded hash is over
*the unpacked, root-stripped tree*, not over the `codeload` tarball.

The fixture demonstrates this without any hand-waving. Three sources fetch the
**byte-identical tarball from one identical URL** and become three different
Nix objects:

| source | `stripRoot` | `hashMode` | resulting hash |
|---|---|---|---|
| `fetchurl` | n/a | `flat` | `sha256-jZkUKv2SV28wsM18tCqNxoCZmLxdYH2Idh9RLibH2yA=` |
| `fetchzip` | `false` | `nar` | `sha256-uF+m0+CSORgGv0cmuIt9aVpY1V88Oq7wypYK8qDIwa8=` |
| `fetchzip` | `true` | `nar` | `sha256-1kJjhtlsAkpNB7f6tZEs+dbKd8z7KoNHyDHEJ0tmhnc=` |

Rows 2 and 3 differ in exactly one attribute, so they isolate `stripRoot` as
the sole cause. Row 1 isolates flat-vs-recursive on the same bytes. Test `t10`
asserts all three, and asserts them from that single URL — an earlier version
of this argument reached for `fetchFromGitHub` as the third identity, which has
a *different* URL and therefore proved less than it claimed. The fixture also
carries a `fetchFromGitHub` source, and `t10.6` asserts it belongs to the same
transformation class, separately.

**What this does and does not block.** An earlier version of this section drew
the wrong conclusion from the right observation. The observation stands:
recovering "the upstream artefact" and stopping there reconstructs none of the
three rows above. The conclusion — *therefore the SWH bridge is blocked* — was
too broad, because it assumed the archive can only be asked for upstream
artefacts. It can also be asked for an object **by its NAR identity** (§1), and
when that lookup hits, none of this transformation machinery is involved.

So the blocker is narrower than it looked:

* **ExtID hit** — the archive holds an object whose `nar-sha256` (or flat
  `checksum-sha256`/`sha512`) equals what the derivation demands. Fetch,
  re-verify, done. No replay, whatever the fetcher did.
* **ExtID miss** — now the transformation matters, and a correct bridge has to
  replay `unpackFile` + `stripRoot` + the caller's `postFetch` shell in the
  same `stdenv` and land on the same NAR hash. That is a build, not a download,
  and it is version-sensitive.

Replay is the fallback path, not the entry path. Until *that* fallback is
demonstrated end to end, no claim of universal SWH recoverability should be
made — but "no SWH bridge is possible until postFetch replay is solved" is not
a claim this file makes any more.

**Why it does not block v0.1.** The escrow preserves the *fixed-output result*
— the object Nix actually asks for — so no transformation ever has to be
replayed. That is the whole reason the escrow is defined at the store-path
layer instead of the artefact layer.

---

## 4. Trust: measured, not assumed

The question was: does a source-only escrow need signing infrastructure?
`nix-source-escrow trust-probe` answers it by experiment. Every case runs with
`require-sigs = true`; the escrow is never signed and its key is never trusted.

| escrowed object | `trusted-public-keys` | result |
|---|---|---|
| content-addressed source FOD | *(empty)* | **accepted** |
| content-addressed source FOD | `cache.nixos.org-1` | accepted |
| input-addressed, `cache.nixos.org` signature | `cache.nixos.org-1` | accepted |
| input-addressed, `cache.nixos.org` signature | *(empty)* | **refused** |
| input-addressed, unsigned (locally built) | `cache.nixos.org-1` | **refused** |

Three conclusions:

1. **`SOURCE_SIGNATURE_REQUIRED = false`.** A fixed-output path is
   self-authenticating: its store path is derived from its content hash, so a
   substituter cannot lie about it. No key management in v0.1. `narinfo` for
   these carries `CA: fixed:...` / `CA: fixed:r:...` and no `Sig:`.
2. **The toolchain tier rides for free.** `nix copy` preserves the
   `cache.nixos.org-1` signatures that came with those paths, and that key is
   already trusted, so escrowing prebuilt binaries needs no key either.
3. **`FULL_AIRGAP_REBUILD` would need one.** Locally built, input-addressed,
   unsigned paths are refused. Row 5 is exactly what a full air-gap mode trips
   on. That is a measured reason to add signing later, not a customary one.

---

## 5. Evaluation-time fetches and IFD

A blanket ban would make the tool useless. The model is a status per source,
and the rule that `UNKNOWN` never silently becomes `PASS`.

| status | meaning |
|---|---|
| `COVERED` | fixed-output derivation with a resolvable origin and expected hash |
| `EXTERNAL_RECOVERY` | fixed-output derivation with **no origin URL at all** — cannot be re-fetched upstream even in principle |
| `QUARANTINED` | reserved for explicit policy exclusions (unused in v0.1) |
| `UNKNOWN` | discovered but not classifiable — **blocks `ESCROW_DISCOVERY_COMPLETE`** |
| `UNSUPPORTED` | a graph construct the algorithm cannot resolve — also blocks it |

`EXTERNAL_RECOVERY` is not hypothetical. The fixture graph contains two:
`stage0-posix-1.9.1-source` and `hex0-1.9.1`, from the nixpkgs minimal
bootstrap. `stage0-posix`'s *builder is a comment* telling you to run
`nix-store --add-fixed --recursive sha256 ./stage0-posix-1.9.1-source` by hand.
There is no URL to lose and no origin to become independent of; the only
recovery paths are a cache, an escrow, or manual reconstruction.

**What discovery does not see, and what covers it.** `nix derivation show -r`
shows the derivation graph. `builtins.fetchTarball` / `fetchGit` / `fetchurl`
with a pinned hash run at *evaluation* time and never appear in it. Pure flake
evaluation rejects the *unpinned* forms, which removes the worst case, but
pinned ones stay invisible. Static enumeration of them is not merely
unimplemented, it is **impossible** at this layer.

The honest consequence: a clean static discovery is not sufficient evidence of
completeness. So `ESCROW_DISCOVERY_COMPLETE` has three values, not two:

| value | when |
|---|---|
| `PARTIAL` | something is known-incomplete: an `UNKNOWN` or `UNSUPPORTED` source, an unresolved flake input, or IFD on this path |
| `UNVERIFIED` | nothing is known-incomplete, but the offline evaluation probe has not passed under real isolation — so eval-time fetches remain unaccounted for |
| `PASS` | nothing known-incomplete **and** the probe passed |

The probe is a distinct step inside the acceptance test, run before the build:
evaluation is forced to complete inside the network namespace with an empty
`XDG_CACHE_HOME`. Any eval-time fetch has nowhere to fetch from and no warm
fetcher cache to hide in, so it fails the probe rather than passing silently.
IFD is probed separately and directly, by re-evaluating with
`allow-import-from-derivation = false`.

An earlier version of this tool reported `ESCROW_DISCOVERY_COMPLETE=PASS` while
printing a note that eval-time fetches were unenumerated. That is precisely the
"`UNKNOWN` silently becomes `PASS`" failure the status model exists to prevent,
committed by the thing enforcing the model.

## 6. Discovery: exact scope of validity

The algorithm is: `nix derivation show -r <installable>`, then every output
whose JSON has a non-null `hash` is a fixed-output derivation. It is
structured-JSON only; no regex over human-readable CLI output.

It is correct for:

* fixed-output derivations reachable in the instantiated graph, for **this
  installable on this system**;
* both plain `env` derivations and `__structuredAttrs` ones — fetcher
  attributes (`urls`, `postFetch`, `stripRoot`) live in different places and
  both are read;
* `builtin:fetchurl` derivations, which have no `urls` in the usual place;
* flake inputs, via a lockstep walk of the *whole* `nix flake archive
  --dry-run --json` tree against the `flake.lock` node graph. Both halves are
  needed. The archive tree is nested, so reading only its root inputs misses
  transitive ones. And a lock node id is not the alias: two inputs both called
  `systems` become nodes `systems` and `systems_2`, so `nodes[alias]` resolves
  the wrong one. Edges are followed through `follows` arrays (which are paths
  from the root node), and results are deduplicated by store path, since two
  aliases can name one object. The fixture contains all four cases on purpose;
  an earlier version of this tool got three of them wrong.

It does **not** cover:

* other systems, other outputs of the same flake, or anything behind
  `nixpkgs.config` differences — the graph is per-installable;
* derivations produced by IFD (they do not exist until evaluation builds them);
* dynamic derivations and floating content-addressed outputs — the output store
  path is read from `env.<outputName>`, which those do not have. Such a source
  is reported `UNSUPPORTED`, never silently dropped;
* eval-time fetches, per §5;
* `builtins.storePath` references to objects with no derivation.

One subtlety worth naming: jq's `//` operator treats `false` as absent, so
`stripRoot = false` would be reported as `null` if written naively. Discovery
uses `has()` instead. This is not pedantry — `stripRoot` is exactly the field
that distinguishes two of the fixture's sources.

---

## 7. Why the build runs in a separate staging store

`preserve` does not trust the developer's `/nix/store`. It builds the
installable into a fresh store under `escrow/work/staging` and copies from
there. The reason is that a path present on the developer machine for unrelated
reasons would otherwise silently satisfy the escrow, and the hole would only
surface later, on someone else's machine.

This also produces the distinction the manifest reports honestly:

* `SOURCES_REQUIRED_BY_PLAN` — sources the accepted build plan actually
  realises. These **must** be in the escrow.
* `SOURCES_DISCOVERED_NOT_REQUIRED_BY_PLAN` — fixed-output sources that exist in
  the graph but are never fetched, because their consumer is substituted as a
  prebuilt binary. In the fixture that is 161 of 164: the whole nixpkgs
  bootstrap. They are recorded, not preserved.

Preserving all 164 would mean mirroring nixpkgs' source corpus, which is
`nixpkgs-swh`'s job, not ours.

**One query, not one process per path.** `nix-store --query --requisites
--include-outputs` in the staging store returns exactly the paths that are
*valid* there — Nix only follows an output edge for an output it actually has.
So that single query answers both questions this stage needs: what is in
staging, and what the plan really realised. An earlier version ran `nix
path-info` once per path to answer the first one: 874 process startups on the
fixture, and on a 30k-path closure a lunch break. The same fix applies to the
copy: `nix copy` is called in batches (`NSE_BATCH_SIZE`, default 256), because
one command line with 30k store paths on it is an `Argument list too long`
waiting to happen.

---

## 8. Retired: the dummy interface, and the offline-substituter gotcha

**The workaround this section documented is gone from the code.** The section
number stays so that older commits, evidence files and cross-references keep
pointing somewhere true.

The gotcha itself is real and still worth knowing. Nix prints
`warning: you don't have Internet access; disabling some network-dependent
features` and then refuses to substitute **even from a `file://` store on the
local disk** — the same command with a working network substitutes from that
same cache without complaint. The original workaround was a dummy
route-to-nowhere device (`dummy0`, `10.99.0.1/24`, a default route to an
address nothing answers) that made the machine *look* online inside the
namespace.

The fix that replaced it is one line of configuration:

```
substitute = true      # in NIX_CONFIG, as an explicit override
```

Reading `src/nix/main.cc`, the offline check only *lowers* `substitute` when it
has not been set explicitly, so an explicit `true` survives it. Reading is not
evidence in this repository, so it was measured: experiments `E1` and `E3`
returned `CONFIRMED` on Nix **2.34.7 and 2.24.9**, in **every run from 6 to
11**, each with a green `E0` baseline. The dummy interface was then removed in
full rather than left switched off, and the experiments that established it were
retired with it — §17a says why a measurement cannot be both the reason for a
change and its acceptance test.

What replaces them as a standing check: with no flag left to disable, the
default acceptance path **is** the configuration those experiments validated,
and `t07`, `t15` and `t16` run it on every suite execution. If a future Nix
reinstates the behaviour, they go red — which is what the dummy interface's
`OFF by default` switch never could have done.

---

## 8a. Retired: the flake-input restore proved the wrong thing

Also gone from the code, section number likewise kept.

`prove.sh` used to copy the locked flake input paths out of the escrow into the
test store before evaluating offline, on the assumption that a locked input is
re-fetched from its origin unless the store already holds it.
`Input::getAccessorUnchecked` says otherwise: for a final input with a
`narHash` it computes the store path and calls `ensurePath`, so a configured
substituter is enough — and the pre-copy was proving that *we* could put the
inputs there, not that a stock consumer would get them. It answered an easier
question than the one being asked.

`E2` and `E3` returned `CONFIRMED` on both Nix versions in every run from 6 to
11. The manual copy is deleted rather than demoted: a diagnostic nobody runs is
indistinguishable from dead code, and `t11` already asserts the real property —
that every flake input, transitive ones included, was served from the escrow
with its origin demonstrably unreachable.

---

## 9. Isolation mechanism, and what it does and does not prove

`unshare -Ur --net --mount`, unprivileged. Inside: loopback, no route out, no
NSS. (There was a dummy device here; §8 records why it is gone.) Every one of those setup steps is
checked, and a failure is `HARNESS_ERROR`, not a verdict about the escrow. The
build runs against a **local store**
(`nix build --store <dir>`), which matters: a local store is served in-process,
so the namespace actually contains the fetching. Going through the
`nix-daemon` would not work — the daemon lives outside the namespace and would
happily fetch on our behalf.

Two Nix settings are needed because `unshare -Ur` maps us to uid 0 with a
single-entry uid map: `build-users-group = ` (empty, or Nix tries to chown the
store to `nixbld`) and `require-drop-supplementary-groups = false` (or
`setgroups` fails).

**What this proves:** under `ESCROW_REPLAY`, the build completed with every
origin — and `cache.nixos.org` — unreachable, from a store that started empty,
with a cold fetcher and eval cache, producing the store path the manifest
predicted. Under `SOURCE_ORIGIN_INDEPENDENCE` the same, except that prebuilt
objects were allowed to come from the binary replica; see §12 for what that
does and does not buy.

**What it does not prove:** `FULL_AIRGAP_REBUILD`. The escrow here contains
prebuilt binaries that originally came from `cache.nixos.org`, carrying its
signatures. Guarantee A is about *sources* surviving the loss of their origins.
Guarantee B — rebuilding everything from source with no trusted binary
substituter — is a different claim, needs the whole bootstrap source corpus
(the 161 above), and needs signing per §4. It is out of scope for v0.1 and is
not implied by a green `ORIGIN_INDEPENDENCE`.

---

## 10. Existing primitives used, and what was deliberately not built

Used as-is: `nix flake archive`, `nix copy`, `nix derivation show -r`,
`nix path-info`, `nix store verify`, `file://` binary caches, fixed-output
content addressing, `nix-store --query --requisites --include-outputs`.

Read but not adopted, with reasons:

* **`copy-tarballs.pl` / `hashed-mirrors`** — flat-only; see §2.
* **`mkBinaryCache`** — builds a cache *as a derivation* from `rootPaths`.
  Elegant, but it wants the closure known at eval time; we want the closure the
  build plan actually used. `nix copy --to file://` is the same artefact.
* **`nixpkgs-swh`** — the prior art for the ExtID/`sources.json` model, and the
  source of the `postFetch` warning in §3. Not a runtime dependency.
* **`mirror-nix`** — same shape as what `nix copy --to file://` already does.
* **Attic / a binary-cache server, as something to *build*** — still not built,
  and now visibly not needed: the escrow is addressed by URL
  (`--escrow-store` / `--escrow-substituter`), so an existing Attic, S3 bucket,
  HTTPS cache or Artifactory Nix repository is a first-class **storage** target
  with no code here. A `file://` directory is the default and the demo backend,
  not the architecture. This is the correction to the v0.1 shape, where PROVE
  asserted `substituters == file://$PWD/escrow/cache` and therefore could not be
  pointed at anything an organisation already runs.

  "First-class **acceptance** target" would be a different and, for now, false
  claim: the acceptance test cuts all egress, so a remote escrow is exactly as
  unreachable inside the namespace as GitHub is. §13 says what the test does
  instead, and what that is worth.

Not built, on purpose: a dependency updater (Renovate, `update-flake-lock`,
`nix-update` and `nvfetcher` already exist — the escrow is a *gate* around
their output, not a replacement), an object store, a cache protocol, a
`fetchFromGitHub` replacement, or a Nix daemon.

---

## 11. Why the acceptance verdict checks the environment before the result

A build that succeeds while `github.com` is reachable proves nothing about
origin independence. An early version of `prove.sh` computed its verdict purely
from build outcomes — exit status, restored source count, output path match —
and so reported:

```text
ORIGIN_INDEPENDENCE=PASS          exit 0
ORIGIN_HOSTS_BLOCKED=github.com,codeload.github.com,gitlab.com,ftp.gnu.org
ORIGIN_HOSTS_REACHABLE=github.com,codeload.github.com,gitlab.com,ftp.gnu.org
```

Every origin reachable, and the same hosts listed as "blocked" in the line
above, because that line printed the hosts we *intended* to block rather than
the ones we had shown to be unreachable.

The verdict is now ordered, and the environmental preconditions come first:

1. `isolationMode == none` → **`NOT_ISOLATED`**. A control run is a distinct
   verdict; it can never be `PASS`, whatever the build did.
2. any origin reachable by name or by address → `FAIL`.
3. any origin that failed to resolve *before* isolation → `FAIL`. If we never
   learned its address, we cannot claim we proved it unreachable.
4. the guarantee itself unavailable on these inputs → **`MODE_UNSUPPORTED`**
   (§12). The build is not even run: no outcome can establish a claim that is
   not on the table, and running one would only produce a failure that reads as
   an accusation against the escrow.
5. an isolation setup operation that failed → **`HARNESS_ERROR`**. Reaching
   this point means nothing was reachable *and* the harness was only
   half-applied, which is precisely the state that used to be indistinguishable
   from an incomplete escrow.
6. substituters not exactly the set this guarantee allows → `FAIL`. Otherwise a
   green build would not tell us where the sources came from.
7. the durable escrow not holding every plan-required source → `FAIL`. Measured
   **before** isolation, against the durable store, and recorded separately
   from the post-build presence check — see below.
8. only then: evaluation, build, restored sources, output path, and zero
   http(s) fetches in the log.

**Why step 7 is separate from the post-build check.** Under `ESCROW_REPLAY` the
old argument holds: the store started empty, nothing was reachable, exactly one
substituter was configured, so a source in the test store came from the escrow.
Under `SOURCE_ORIGIN_INDEPENDENCE` a second substituter is configured, and an
approved cache can perfectly well carry source FODs too — so presence after the
build no longer attributes anything. The attribution now comes from a direct
question put to the durable escrow before isolation, recorded as
`sourcesInEscrowBeforeIsolation`. It also makes `test-origin-independence`
sound on its own, instead of quietly depending on someone having run `verify`
first.

Measured reachability comes *before* the harness check on purpose: a reachable
origin invalidates the run whatever the cause, and it is the more specific
finding. `HARNESS_ERROR` is what is left when the environment was quiet but the
harness could not prove it built the environment it claims. None of `NOT_ISOLATED`, `HARNESS_ERROR` or `MODE_UNSUPPORTED` is accepted by
`--expect-fail`: a negative control has to fail because the escrow was
incomplete, not because the test broke or the claim was unavailable.

Reporting follows the same rule. `ORIGIN_HOSTS_PROVEN_UNREACHABLE` is computed
from the probe results, so it lists what was demonstrated; the intended
blocklist is not printed as though it were a finding.

The general form of the mistake is worth naming, because it is easy to repeat:
**the tool that enforces "`UNKNOWN` never silently becomes `PASS`" is itself
subject to that rule.** Test `t12` now runs the two adversarial cases — a
control run, and a run that *claims* isolation while having none — and requires
both to refuse.

---

## 12. Three guarantees, named separately

`ORIGIN_INDEPENDENCE` was one word doing two jobs, and the expensive job was
hiding the cheap one.

| guarantee | escrow holds | acceptance test allows | cost |
|---|---|---|---|
| `SOURCE_ORIGIN_INDEPENDENCE` | plan-required fixed-output sources, flake inputs, the flake source | escrow **plus** the approved binary tier | small: sources only |
| `ESCROW_REPLAY` (default) | the whole realised closure | escrow **only** | large: the closure |
| `FULL_AIRGAP_REBUILD` (not implemented) | the whole bootstrap source corpus | escrow only, **and everything is built from source** | largest |

**Why the middle one is the default.** It is the strongest thing this harness
can demonstrate, and it is what v0.1 already proved. It stays the default so
nobody gets a weaker result by accident.

**Why the first one exists.** `ESCROW_REPLAY` places the entire realised
closure — 876 objects, 87 MB, for a fixture that consumes five sources — into
the set you must **retain durably and be able to audit** for every revision you
gate.

State that precisely, because the imprecise version invites a correct
objection. The cost is a **retention obligation**, not a transfer cost:

```
network / storage WRITE AMPLIFICATION   !=   long-term PRESERVATION OBLIGATION
```

A content-addressed store deduplicates by construction, so a dependency bump
transfers what changed, not the whole closure. The loose phrasing is false, and
a reader who knows how a CAS works will discard the rest of the section on the
strength of it. What actually grows with the stronger guarantee is the number of
objects you have promised to keep alive and answer for.

*(`u22.1` guards this paragraph, and the first draft of it tripped its own
guard by quoting the wording it rejects — the same defect as `t21.5` one commit
earlier, §19b. The rule generalises past refusal messages: prose that argues
against a phrase must not contain the phrase, because no text search can tell
the two apart.)*

The cheap mode narrows that promise to the objects that have an origin to
lose. What it proves
is exactly:

> the disappearance of the source origins does not break this build, because
> the source identities are held by us.

What it does **not** prove is independence from the binary tier. Both strings
are written into `origin-independence.json` (`guarantee.proves` /
`guarantee.doesNotProve`) and printed in the report, so the weaker claim cannot
be quoted as the stronger one.

**Where the prebuilt tier comes from. Two wrong answers first.**

*Wrong answer one: copy it out of staging.* The first implementation filled the
binary replica with `closure − sources` taken from the **staging store**.
Staging builds locally whatever it cannot substitute, so an object *this
machine happened to produce* was handed to the acceptance test as though the
approved cache had it. The evidence then read "the build works given the
approved binary tier" about a tier that may never have held the object. Not a
trust problem — a fidelity problem: the model of the third party was made out
of local build output.

*Wrong answer two: infer what was substituted, and refuse when the tier lacks
it.* The fix for the above read a cache signature on a staging path as proof
that the path had been **substituted**, and then declared the whole mode
unavailable when the approved tier could not supply such a path. Both halves
were wrong:

* a signature is not proof of substitution — Nix signs locally built paths too,
  whenever `secret-key-files` is configured;
* and more fundamentally, *"the previous staging run chose to download X" says
  nothing about whether X can be built.* The mode already permits a rebuild for
  everything the tier does not hold. A signed path has no special metaphysical
  status. Refusing on that basis is: "yesterday I took the bus to work,
  therefore today, without a bus, the journey is logically undefined." No. Try
  walking.

**The answer with no heuristic in it.**

```
realised closure
      |
      +-- escrowed source material              -> escrow
      |
      +-- *.drv                                 -> provided to nobody. The test
      |                                            evaluates the flake and
      |                                            instantiates them itself;
      |                                            asking a binary cache for a
      |                                            derivation is a category error
      |
      +-- everything else: ask --binary-tier URL
                |
                +-- it has it   -> binary replica, copied FROM THE TIER
                |
                +-- it does not -> provided to nobody. The acceptance build
                                    has to produce it, and whether it can is
                                    the test's answer to give
```

`replicaPaths = tierCandidates ∩ tier`, `notProvidedPaths = closure −
escrowPaths − replicaPaths`, and `closure.json` records all three so the
partition is checkable rather than assertable. Nothing anywhere reads a
signature. The acceptance build is the judge: whatever it needs and nobody
supplied, it has to build, or it fails — and either way that is a measurement.

One sentence of care about the claim. `notProvidedPaths` is "supplied by
nobody", **not** "built by the test". A build-time dependency of an object the
tier does supply is never needed in the replay at all, so it is neither
supplied nor built, and that is a perfectly correct `PASS`. What the guarantee
therefore says is the narrower and true thing: *anything the build actually
needed that neither the escrow nor the tier supplied had to be built inside the
test.* An earlier version of `guarantee.proves` claimed the wider one.

**What `MODE_UNSUPPORTED` is actually for.** Not "one particular cache lacks
one particular path" — that is a data condition a real build can resolve by
building the thing. It is for a claim this harness cannot *model* on these
inputs, and there is exactly one such case today: the escrow was **preserved**
for one guarantee and is being **proven** against another. The path sets on
disk then do not correspond to the claim, so no build outcome would mean what
the verdict says. It can never be `PASS`, and `--expect-fail` refuses it,
because "the claim was unavailable" is not "the escrow was incomplete". Test
`t18` triggers it deterministically.

**What the harness still cannot do.** It cuts all egress rather than filtering
it, so the approved tier is present as a local replica rather than as the real
cache. Its *contents* are now faithful; its *reachability* is still simulated.
Selective egress is the same missing piece as in §13.

**Why `FULL_AIRGAP_REBUILD` is still only a row in this table.** It needs the
whole bootstrap source corpus (the 161 in §7) and signing, per §4 row 5:
locally built, input-addressed, unsigned paths are refused. That is a measured
prerequisite, not a guess, and it is out of scope until the two implemented
modes have been run in anger.

---

## 13. A remote escrow is replayed, not reached

Making the escrow a URL fixed the storage layer and immediately exposed that
the network model had not moved. Under `unshare --net` with no route, this:

```
substituters = https://attic.example.com/escrow
```

is not "the escrow is the only substituter". It is "there are no substituters",
and a build that somehow went green would be telling you about something other
than the escrow. Configuring a remote store as the substituter *inside* the
blackout and calling the result a proof would be exactly the class of mistake
§11 exists to prevent — this time committed by the storage refactor.

So a non-local escrow is **materialised before isolation** into a local proof
replica, and the test replays from that:

```
durable escrow (s3:// | https:// | ssh-ng:// | file://)
        |
        |  before isolation: ask it for every object in escrowPaths,
        |  copy them, and refuse to continue if it comes up short
        v
proof replica (file://, local)
        |
        |  unshare -Ur --net --mount
        v
acceptance build
```

The evidence records both ends and which one the test used
(`replaySource.durableEscrow`, `replaySource.escrowUsedByTest`,
`replaySource.escrowMode` = `direct` | `materialised`). A `file://` escrow is
used directly; there is nothing to copy.

**Requested is not the same as reachable.** `nix copy` copies *closures*, so
"we asked for 53 roots" is not "53 objects arrived", and reporting the size of
the request as though it were the size of the result is the same genre of
mistake in a new hat. The stores the test will actually use are therefore
listed and counted:

```
REPLAY_OBJECTS_REQUESTED=53
  REACHABLE_BY_TEST=61  ARRIVED_AS_CLOSURE=8
  NOT_PROVIDED_BUT_REACHABLE=0
```

That last line is the one that matters. Under `SOURCE_ORIGIN_INDEPENDENCE` the
manifest says a set of objects is supplied by nobody, so anything the build
needs from that set it has to build. If a closure copy quietly put one of them
next to the build, that stops being true — the object could have been obtained
instead — so a non-zero `notProvidedReachableByTest` is a `FAIL` with that
reason, not a footnote.

**What this establishes.** Before isolation: the durable escrow was asked for
every object and produced every one of them. After isolation: that exact set
replays the build with no network at all.

**What it does not establish.** Anything about the durable store being
reachable during a blackout. That is the store's own availability problem, and
it is not what this project is for — an escrow whose S3 bucket is down is a
paged incident, not a broken guarantee about source origins. A future selective
harness that permits the escrow endpoint and blocks everything else would prove
the stronger thing; a `nftables`/`pasta` allowlist is the shape, and it is not
built.

Test `t16` runs the whole path against a real HTTP binary cache served out of
the fixture escrow, and asserts that the test replayed from `file://` while the
durable escrow stayed `http://`.

---

## 14. Evidence that cannot say which code produced it

`E1 = CONFIRMED` is worth nothing two commits later if nothing records which
commit it was confirmed on. Every evidence file now carries:

```json
"provenance": {
  "toolRevision": "2c50fdebeae397954ace167e06495d1e43a8c73e",
  "revisionSource": "flake",
  "workingTreeDirty": false,
  "nixVersion": "nix (Nix) 2.34.7",
  "manifestSha256": "...",
  "closureSha256": "..."
}
```

**Where the revision comes from, and the version of this that did not work.**
The first attempt ran `git -C "$NSE_ROOT" rev-parse HEAD` and, when that came
back empty, added `git` to the package's `runtimeDeps`. That fixes nothing.
`NSE_ROOT` for an installed tool is `/nix/store/…-nix-source-escrow-0.1.0`,
the `src` filter deliberately drops `.git`, and an immutable store path has no
working tree to be dirty in the first place. Shipping a `git` binary to read a
repository that was never packaged is like shipping `cat` for a file you did
not install. Every `nix run` would have recorded a null revision.

So the revision is **stamped in at build time** from the flake itself
(`self.rev or self.dirtyRev`), written to
`$out/share/nix-source-escrow/build-info.json`, and the runtime `git` query
survives only as the dev-checkout fallback:

| `revisionSource` | revision | `workingTreeDirty` |
|---|---|---|
| `flake` | stamped at build time | `false` for a clean flake, `true` for a dirty one, `null` when the source has no VCS info |
| `git-checkout` | `git rev-parse HEAD` | `true`/`false`, with untracked files counting as dirty |
| `unknown` / `*-no-revision` | `null` | `null` |

`gitDirty` counting untracked files is deliberate for a checkout: a stray
`lib/*.sh` that `nix flake check` never saw is exactly the kind of thing that
makes a result unreproducible. For a packaged build the concept does not apply
and the field says so.

This distinction is only observable through the **built** package, which is why
`t19` runs `nix build .#nix-source-escrow` and then asserts on
`./result/bin/nix-source-escrow`. A test against `$PWD/bin` would have passed
for the broken version.

One more trap worth naming, because this repository documents it in §6 and then
walked into it anyway: reading the stamped flag with `jq '.workingTreeDirty //
null'` returns `null` for a **clean** build, because jq's `//` treats `false`
as absent. `has()` is the only correct form. Unit test `u11.4d` exists to keep
it that way.

The report prints `TOOL_COMMIT=<short> [<source>] (clean|WORKING TREE DIRTY)`,
so a pasted report block is traceable to a tree, and an acceptance verdict is
bound to the `manifest.json` it judged rather than to whichever manifest
happens to be on disk when someone reads it later.

---

## 15. What the first real execution found

Everything above was written before this repository had ever run. The first
execution — a GitHub Actions matrix over Nix 2.34.7 and 2.24.9 — produced one
result and four defects, and the shape of the defects is the point.

**The result.** On Nix 2.34.7: `ESCROW_REPLAY` passes end to end, 874 of 874
replayed objects reachable, `notProvidedReachableByTest = 0`, provenance naming
the exact tested HEAD on a clean tree, host detection correctly identifying an
Azure runner, and `E0/E1/E2/E3 = BASELINE_OK / CONFIRMED / CONFIRMED /
CONFIRMED`. Discovery found 165 sources, 163 covered, 2 external-recovery —
identical to the numbers this repository had been quoting.

**The defects.** Four, and three of them are the same mistake:

| | what happened | the shape of it |
|---|---|---|
| discovery | `nix derivation show` emits `{version, derivations}` on 2.34.7 and a flat map on 2.24.9. The code read `.derivations // {}`, so on 2.24.9 it found **zero** derivations, zero sources, and reported a complete discovery | unreadable → **empty** |
| trust probe | metadata crossed a TSV, a signed object has an empty `ca` field, and `read` with a tab IFS collapses `\t\t`. Every signed and unsigned object was classified content-addressed, three trust cases reported `skipped` — while the composition counter, parsing the same file with `awk -F'\t'`, printed the correct numbers | empty field → **next column** |
| provenance | `jq '.workingTreeDirty // null'` returned `null` for a clean build, because `//` treats `false` as absent | false → **absent** |
| source mode | `local out` does not clear the export attribute, and `nix develop` exports `$out`. A multi-megabyte path-info document went into the environment of every child; the next exec died `E2BIG`, exit 126, and the whole `SOURCE_ORIGIN_INDEPENDENCE` run was recorded as red | a crash → **a verdict** |

Only the last is a plain bug. The other three are the *same* bug wearing
different clothes, and all three produced green, plausible, entirely vacuous
results. That is why §16 exists.

**What caught them.** Not review — five rounds of it had read this code
closely. The discovery failure was caught by `t03.3 "the plan actually required
some sources"`, an assertion that exists for no reason except that zero would
otherwise pass. The trust failure was caught only because two independent
readers of one file disagreed in the same report. Both are cheap. Both are the
kind of check that feels redundant right up until it is the only thing standing
between you and a confident wrong answer.

---

## 15a. What the runs after it found, including two instruments that measured themselves

Fixing the four defects in §15 got the suite far enough to fail somewhere new,
which is the only useful kind of progress here.

**Run 6** got 117/18 on 2.34.7 and died in the binary tier. The cause was the
presence parser: `nix path-info --json` answers `"<path>": null` for an object
it does not have and exits `0`, and reading `keys[]` turned every path we asked
about into a path the tier held. Fixed in §16; every `t15` assertion, including
the three added to catch exactly this, has been green since.

**Run 7** was green from `t01` to `t19` and then died inside `t20` — the test
added in the same commit as the fix it guards — because of

```
find … -name '*.narinfo' | head -1 | xargs …
```

`head` exits, `find` takes `SIGPIPE`, `pipefail` makes the substitution fail,
and `set -e` ends the suite before it can print a result.

**Run 8**, on 2.34.7, is the first end-to-end green: every step of the matrix
leg, the full acceptance suite included. On 2.24.9 it is 135/9, and all nine
failures are one finding (below). It also revealed the second self-measuring
instrument: the probe step added to diagnose that very finding ran
`nix derivation show` **without `-r`**, so its document held one derivation —
the top-level one, which is not fixed-output — and it answered "no fixed-output
derivations found" about a graph with 165 of them.

Three defects in three runs where the harness reported on itself rather than on
the code: a test that aborted its own suite, a probe that measured its own
invocation, and (in `u14.3`) an assertion that could only pass while the code
under it was fail-open. The rule in §16 is about parsing an answer; these are
about *asking the question*, and they fail the same way — silently, and green.
A test or probe is only evidence if you can say what a red one would have
looked like.

**The one open finding.** On Nix 2.24.9 discovery reports `COVERED=146`,
`EXTERNAL_RECOVERY=19`, `WITH_POSTFETCH=0` where 2.34.7 reports `163`, `2` and
`3` — on a **byte-identical closure** (`closureSha256` matches exactly) with the
same 638 derivations and the same 165 fixed-output sources. The graph is
identical; what differs is how a derivation carries its *attributes*, and
`urlsOf` reads the origin URL out of `structuredAttrs` or `env`. Nine tests
name it precisely: `t01.3`, `t01.4`, `t01.7` and all of `t10`, every one an
assertion about a URL, a hash mode or a `postFetch`. `ESCROW_REPLAY` still
passes on that version, so this is a defect in what the evidence *says about
origins*, not in what the escrow *holds*.

**Resolved, by measurement, in run 10.** Two things were wrong, and the second
one is the finding:

* **The key.** The envelope keys its map by the bare object name
  (`013mqc5…-expr-strcmp.patch.drv`); the flat map keys it by the full store
  path. `discover.sh` built `drvPath` as `"$storedir/" + key`, so every 2.24.9
  run recorded `/nix/store//nix/store/…drv` for all 638 derivations.
  `nse_drv_map` now normalises the key for both schemas. `u12` could not have
  caught it: both its fixtures used a full path and `u12.5` compared the map
  *length*.
* **The 17.** They are `__structuredAttrs` derivations, and the two versions put
  those attributes in different places:

```
2.34.7   "structuredAttrs": { "urls": [...], "postFetch": ..., "stripRoot": true }
2.24.9   "env": { "__json": "{\"urls\":[...],...}", "out": ... }
```

  Reading only `structuredAttrs` and `env` saw `{"__json": …, "out": …}` — no
  `url`, no `urls`, no `postFetch` — and filed 17 sources that have perfectly
  good origins under `EXTERNAL_RECOVERY`, "can never be re-fetched upstream,
  only restored from a cache". Exactly 17, which with the 2 genuinely
  origin-less minimal-bootstrap sources is the 19 that version reported. §16
  again, one level further down: a representation we could not read became an
  object with nothing in it, and the only trace was a count that moved.

The route to it is the part worth keeping. The `__structuredAttrs` story was
told *first*, on no evidence, and then declared dead — also on no evidence,
because the probe printed the first two fixed-output derivations in the
document and both were plain `fetchurl` with identical attributes on both
versions. A non-representative sample refuted a correct hypothesis as
confidently as it would have confirmed a wrong one. What settled it was making
the probe **name** the derivations that differed instead of counting them: 17
lines reading `__json,out` and two reading `outputHash,…`, and the arithmetic
closed on the spot.

`nse_attr` / `nse_urls_of` now live in `lib/common.sh` as `NSE_JQ_DRV_ATTRS`,
read `env.__json` when there is no parsed `structuredAttrs`, and **error** on an
`env.__json` that is not JSON. Tests `u16.1`–`u16.7`, no Nix required.

---

## 16. Empty is data only after a successful parse

*(Stated generally, with no Nix in it, in `EXPERIMENT-PROTOCOL.md` §2 — that
file is the portable form of this section, §16a and §17–§17d.)*

The rule, stated once, because three separate defects were the same violation
of it:

```
MISSING  /  UNPARSEABLE  /  UNKNOWN_SCHEMA     is not     EMPTY
```

And its corollary, for anything a build plan guarantees is non-empty:

```
expected non-empty  AND  observed zero   ->   FAIL or UNVERIFIED, never PASS
```

`0 of 0 = 100%` is a perfectly effective strategy for producing green reports,
and a proof tool that cannot tell it apart from a real result is not a proof
tool. Enforced in four places:

* `nse_drv_schema` returns `envelope`, `flat-map` or `unknown`, and
  `nse_drv_map` **refuses** on `unknown` rather than yielding `{}`. There is no
  `// {}` anywhere on that path.
* discovery aborts if it parses **zero derivations** from a document Nix
  produced. A build plan always instantiates at least its top-level derivation,
  so zero is never a fact about the graph — only about our reading of it.
* `ESCROW_DISCOVERY_COMPLETE` is `UNVERIFIED`, never `PASS`, when zero
  fixed-output sources were discovered, and the report names the schema and
  derivation count so the reader can see why.
* store metadata travels as JSONL through one shared classifier
  (`NSE_JQ_CLASSIFY`), because JSON has exactly one answer to "what is an empty
  field" and two hand-rolled parsers had two different ones.

* `nix path-info --json` answers `"<path>": null` for a path the store does
  not have, and exits `0`. `keys[]` therefore reported **everything asked
  about** as present. `nse_pathinfo_present_keys` keeps only non-null values,
  understands the object and array shapes, and **errors** on a third — because
  "I cannot read this answer" is not "nothing is here". This is the same rule
  one level lower than the others: a key is structure, a non-null value is the
  fact.

Tests `u12`, `u13`, `u14` and `u15` fail if any of these regress, and they need
no Nix to run.

### 16a. The corollary the fifth review added: a claim is not a delivery

The rule above is about reading an answer. Its twin is about acting on one.
A store saying it holds a path and a path arriving are two facts, and the
distance between them is exactly where `SOURCE_ORIGIN_INDEPENDENCE` lives:

```
tier CLAIMS path        (probe)
tier DELIVERS path      (materialise, then RE-QUERY the destination)
```

So the binary tier is probed and materialised as separate stages with separate
evidence, `materializedRoots` is read back out of the destination rather than
inferred from the request, and a copy that fails is **classified**:

* the source still claims to hold it -> `BINARY_TIER_ERROR`, the run dies;
* the source has revised its claim   -> recorded in `tier-revised-absent.txt`;
* an unexplained gap                 -> fatal.

There is deliberately no fourth branch. Relabelling an ambiguous failure as
"unavailable from the tier" would hand it to the acceptance build as something
the test is *permitted* to rebuild, and the verdict would then be measuring the
harness's confusion rather than the tier. Test `t20` drives this with an HTTP
tier that serves a `.narinfo` for a `.nar` it does not have.

---

## 17. Pre-registration: what the removal of the two workarounds must and must not change

Written **before** the removal is made and before the run that judges it, which
is the only time this document is worth anything. §16a says a test is evidence
only if you can say what a red one looks like; a *change* is evidence only if
you say, in advance, which observables it is allowed to move.

### What is already established

`E1` (no dummy interface), `E2` (no manual flake-input restore) and `E3` (both
dropped — the current default) are `CONFIRMED` on **both** Nix versions, in
**every** run from 6 to 11, with `E0` green each time so the variants are
attributable. Run 11 adds that the two versions agree on every discovery
cardinality as well. This is repeatability, not one lucky Tuesday, and it holds
across the fixes to four separate instrumentation defects — including two that
were live in runs 6 and 7. The conclusion is therefore not "these look
removable": it is **the dummy interface and the manual input restore are not
necessary parts of the confirmed mechanism**.

What has not been demonstrated is that the *code* implementing them can be
deleted without changing anything else, which is a different claim and needs
its own destructive experiment.

### The sequence, kept surgical

1. `experiments.json` provenance repaired, no behavioural change. Done: the
   summary read `.provenance.gitCommit` / `.gitDirty` (fields that never
   existed) and `//`-defaulted a `false` conclusion to `"unknown"`, so eleven
   runs printed `measured on: unknown` and `dummy interface still needed:
   unknown` beside a JSON block carrying the exact commit and `false`. `u17`.
2. **This section.**
3. One commit that deletes the dummy interface, demotes the manual restore to a
   diagnostic, and removes §8 — and nothing else.
4. A cold matrix run on **that** commit, same full route: `unit-shell` →
   `flake check` → `t00`–`t20` → `E0`–`E3` → discovery counts →
   `closureSha256`.

### The verdict, defined in advance

`REMOVAL_VALIDATED` requires **equivalence with run 11**, not merely green:

```
nix 2.34.7 and nix 2.24.9, both:
  unit-shell        = N/0        (N grows only by tests added in step 3)
  flake check       = pass
  t00-t20           = 144/0      minus any test that existed ONLY to
                                 exercise the deleted path, each such
                                 removal named in the commit
  E0                = BASELINE_OK
  E1 / E2 / E3      = CONFIRMED

discovery, both versions:
  FOD_SOURCES=165  COVERED=163  EXTERNAL_RECOVERY=2
  WITH_POSTFETCH=3  ON_KNOWN_FORGE=38  638 derivations

closureSha256       = 9243083eb0146c72362229c734fa78f6b3b1200eab9a8be06ccbbe8fe7daf8ec
                      identical on both versions AND equal to run 11
```

### The red outcomes, also defined in advance

Each of these is a **result**, not an obstacle to be worked around, and each is
written down now so that no explanation can be invented after the fact:

| observation | what it means | what happens |
|---|---|---|
| any `E` outcome moves off `CONFIRMED`/`BASELINE_OK` | the workaround was load-bearing after all, and eleven runs of `CONFIRMED` were measuring something else | **revert the deletion**, record why, and treat §8 as re-established |
| `t00`–`t20` red anywhere except a test deleted with its subject | the removal touched something it had no business touching | revert, isolate, retry as a smaller change |
| a discovery cardinality moves | the deletion changed what is *discovered*, which it has no path to do | stop; this is a defect in the removal, not a new fact about the graph |
| **`closureSha256` changes** | see below | classify **before** re-running, never after |

`closureSha256` deserves its own line because it is the one that will tempt an
explanation. The removal touches the acceptance harness — how the test store is
isolated and how flake inputs get there — and **not** the derivation graph of
the fixture. There is therefore no legitimate route from this deletion to a
different closure. If the hash moves, the correct reading is *the deletion
changed the build*, and the work is to find out how, not to write a paragraph
about why the new hash is fine. The one exception agreed in advance: if the
deletion also removes a *derivation input* of the fixture — it does not, and if
step 3 finds that it would, that is a different change needing its own
pre-registration.

### Why this is worth more than a twelfth green run

Re-running unchanged code produces the same green and answers nothing new. An
amputation that leaves every observable in place is a much stronger statement
about the mechanism: it says the confirmed behaviour did not depend on the
parts we removed, which is exactly what `E1`–`E3` claim and cannot themselves
prove — they measure a *disabled* workaround, not an *absent* one.

### 17a. The pre-registration had a defect, and it was found before the run

Written the same day as §17 and **before** the deletion commit, which is the
only place this belongs.

§17 requires, as a condition of `REMOVAL_VALIDATED`:

```
E0                = BASELINE_OK
E1 / E2 / E3      = CONFIRMED
```

That criterion is **unsatisfiable by the change it pre-registers**, and not
because of anything about the change. `E0`–`E3` are defined by toggling exactly
the two mechanisms being deleted:

```
E0   --dummy-interface     --manual-input-restore     (the legacy baseline)
E1   --no-dummy-interface  --manual-input-restore
E2   --dummy-interface     --native-input-restore
E3   --no-dummy-interface  --native-input-restore     (today's default)
```

Delete the mechanisms and there is no independent variable left to vary. An
experiment cannot outlive its own manipulandum. Requiring `E1 = CONFIRMED`
after the removal is requiring a measurement that cannot be taken — and the
tempting move, once the run comes back without those lines, is to decide
afterwards that they were never really part of the criterion. That is the
failure mode §17 exists to prevent, so it gets corrected here instead, in
advance, with the reasoning visible.

**The amendment.**

* `E0`–`E3` are **retired at the deletion commit**, not carried forward. Their
  final values are frozen in `evidence-runs.json` and in the run table in
  `EVIDENCE.md`: `CONFIRMED` on both Nix versions, in every run from 6 to 11,
  each with `E0` green. Those measurements are the *justification* for the
  deletion; they cannot also be its *acceptance test*.
* What survives is `E3`'s content, and it survives in the place that matters:
  once the workarounds do not exist, the default acceptance path **is** the
  `E3` configuration. `t07` — the acceptance criterion — `t15` and `t16`
  already run it and already assert on it. After the removal they are not
  merely *analogous* to `E3`; they are `E3`, with no flag left to disable.
* `REMOVAL_VALIDATED` therefore drops the `E` lines and keeps everything else
  in §17 unchanged, with one addition: `tests/experiments.sh` must be retired
  in the same commit rather than left calling flags that no longer parse. A
  harness that silently stops measuring is worse than one that is deleted.

The rest of §17 stands as written, `closureSha256` included. Note what this
amendment does **not** do: it does not relax a single observable of the system
under test. It removes a requirement that was never about the system at all —
only about the instrument, which the change dismantles on purpose.

### 17b. What the removal run actually returned

Run 15, commit `913df97`, judged against §17 and §17a exactly as they were
written before it.

**Every pre-registered observable is unchanged from run 11**, on both Nix
versions: `unit-shell` 111/0, `flake check` pass,
`FOD_SOURCES=165 COVERED=163 EXTERNAL_RECOVERY=2 WITH_POSTFETCH=3
ON_KNOWN_FORGE=38`, 638 derivations, 874 objects, `ORIGIN_INDEPENDENCE=PASS`,
and

```
closureSha256 = 9243083eb0146c72362229c734fa78f6b3b1200eab9a8be06ccbbe8fe7daf8ec
```

identical across both versions and equal to run 11's. The hash that §17 said
must not move did not move, so no paragraph explaining a new one is needed —
which was the point of naming it in advance.

`t00`–`t20` came back **143/1** on both legs, and the one failure is the
finding:

```
t07.9 flake inputs were restored from the escrow with no network
      assert  .restoreExit == 0
```

`restoreExit` was `restore_rc`, the exit code of the manual `nix copy`. On the
default path that block was gated behind `NSE_INPUT_RESTORE = manual` and never
executed, so `restore_rc` kept the `0` it was initialised with. **The test
asserted `0 == 0` about a command that did not run**, under a name promising a
property it never touched. It has been vacuous since `native` became the
default, and nothing could have revealed it except deleting the field it read.

That is the fifth instrument in this project that could not go red, and the
first one caught by a pre-registered criterion rather than by accident. §17's
red table calls for reverting when a test outside the deleted path fails; this
one *is* inside it — its only subject was the deleted mechanism — but §17a's
allowance was conditioned on naming such tests **in the deletion commit**, and
this one was not named because it was not noticed. So it is recorded as a miss
in the pre-registration, not waved through.

**The repair is not a deletion.** `t07.9`'s *name* described something real that
nothing else asserts: `t11` checks the inputs are in the escrow and that GitHub
was unreachable, not that the inputs reached the store the build used. So
`prove.sh` now measures it — `flakeInputsRequired` and
`flakeInputsPresentAfterBuild`, counted in the test store after the isolated
build — and `t07.9`/`t07.9a` assert the count is non-zero and complete. A test
that cannot fail is worse than no test; replacing it with one that can is the
only honest way to close this.

While repairing it, the same post-check was found counting
`nix path-info --json` with `keys | length` — the run-6 P0, still live in the
code that decides `t07.7`. It has been reporting `4/4` correctly because the
paths really were there, and would have reported `4/4` just as confidently if
they had not been. Fixed in the same commit, named here rather than folded in
silently; it can only lower a count, never raise one.

### 17c. And the repair over-claimed in the other direction

Run 17, commit `102d5a1`. Every pre-registered observable still unchanged —
`closureSha256` still `9243083e…f8ec`, discovery still `165/163/2/3/38`,
`REQUIRED_SOURCES_PRESENT_AFTER_BUILD` still `4/4` after the null-counting fix
(so that count was right, just unsoundly derived) — and `t00`–`t20` came back
**144/1**. The new failure is the new assertion:

```
FLAKE_INPUTS_PRESENT_AFTER_BUILD = 2/4
t07.9a  every one of them is in the test store, with no network   -> false
```

**2 of 4 is Nix being correct.** A locked flake input is materialised when
evaluation *reaches* it; one the evaluation never touches is never fetched,
because nothing ever asks for its accessor. The fixture locks two inputs and
uses both; the other two are transitive entries in the lock that this
particular output's evaluation does not visit. "All four are in the test store"
is not a property the mechanism has ever had.

So `t07.9` went from asserting nothing (`0 == 0` about a command that never ran)
to asserting too much, in one commit. Both are the same error underneath —
writing down what the test's *name* suggests instead of what the mechanism
*promises* — and the second one at least failed loudly on first contact, which
is the whole difference between the two.

The assertion now says what the mechanism promises, and says it by **name**:

```
flakeInputsPresentAfterBuildNames = ["gitignore-src", "nixpkgs"]
```

`t07.9a` requires exactly those two — the inputs the fixture itself locks —
obtained in a store that started empty with every origin unreachable. A bare
count would have passed on any two. `t07.9b` requires that every input Nix did
materialise is one the escrow holds, so nothing can arrive from somewhere the
evidence does not account for. The report prints the names next to the count,
with a note saying why the count is normally below the total — a reader who
sees `2/4` should not have to rediscover this section.

The number itself is now evidence: if that set of present inputs changes on a
future Nix, `t07.9a` goes red.

**And the verb matters, so it is pinned here.** `2/4` is a **presence**
measurement. What it establishes: *the tested offline evaluation succeeds while
only these two of the four locked flake inputs remain present after the build.*
It does **not** establish that either present input is *necessary* — nothing has
removed a surviving input to see the build fail. That would be a separate
ablation with its own pre-registered red trace, and it has not been run. After
six instruments that could only agree with their author, this experiment has
earned the right to be pedantic about verbs.

### 17d. Verdict: REMOVAL_VALIDATED

Run 18, commit `a4f07ea`. Green on every step of both matrix legs.

```
                     nix 2.34.7      nix 2.24.9
  unit-shell          111 / 0         111 / 0
  flake check         pass            pass
  t00-t20             146 / 0         146 / 0

  FOD_SOURCES=165  COVERED=163  EXTERNAL_RECOVERY=2
  WITH_POSTFETCH=3  ON_KNOWN_FORGE=38  638 derivations   both versions
  REQUIRED_SOURCES_PRESENT_AFTER_BUILD = 4/4            both versions
  FLAKE_INPUTS_PRESENT_AFTER_BUILD     = 2/4            both versions
                                         (gitignore-src, nixpkgs)

  closureSha256 = 9243083eb0146c72362229c734fa78f6b3b1200eab9a8be06ccbbe8fe7daf8ec
                  identical across versions, and equal to run 11's
```

Every observable §17 pre-registered before the deletion is unchanged. The
system does not notice that the dummy interface and the manual flake-input
restore are gone, which is exactly the claim `E1`–`E3` made and could not
themselves prove: they measured a *disabled* workaround, this measures an
*absent* one.

**Scope, stated once and not widened.** This is a result about *the tested
configuration*: this fixture, this flake, `x86_64-linux`, Nix 2.24.9 and 2.34.7,
on a GitHub Actions runner. It says these mechanisms are not necessary for the
observed result **here**. It does not say Nix never needs them — two CI jobs do
not license a universal claim, and the world has enough of those already.

Two things are stronger than they were before the amputation, not merely
unchanged. `t07`, `t15` and `t16` now run the `E3` configuration with no flag
left to disable, so a future Nix that reinstates the offline-substituter
behaviour turns them red rather than being quietly worked around — the deletion
removed a region of state space in which a regression could exist unexamined,
which raises the falsifiability of the system rather than only its tidiness.
And `FLAKE_INPUTS_PRESENT_AFTER_BUILD` is a measured set where `restoreExit`
was a constant: both versions produced the same two names, and `t07.9a` says so
if that set ever changes. (Presence, not necessity — §17c.)

The cost of getting here was four runs and three wrong assertions in a row —
one that asserted nothing, one that asserted too much, and a pre-registration
whose own acceptance criterion could not be met by the change it
pre-registered. All three were caught before they could be written up as a
result, and §17a, §17b and §17c say which was which.

---

## 18. This line of work is closed

**The result, in one statement.**

> Within the tested envelope, `E1`–`E3` are confirmed, the claimed necessity of
> the workarounds is falsified, and removal of those workarounds preserves every
> pre-registered observable. The experiment protocol itself was prospectively
> validated, by rejecting a defective measurement criterion **before** the
> intervention.

The second sentence is the one that could not have been written after any
earlier run. Everything up to run 14 explains past failures; run 15 onward is
the protocol refusing a bad instrument in advance.

Eighteen runs. Another cold run of the same commit costs time and yields
almost no information, so there will not be one: the next run should exist
because a **new falsifiable claim** does, not because green is pleasant.

```
E1-E3 hypothesis .................. CONFIRMED
workaround necessity .............. FALSIFIED
workaround removal ................ REMOVAL_VALIDATED
tested envelope ................... Nix 2.24.9 and 2.34.7, x86_64-linux,
                                    this fixture, GitHub Actions ubuntu-latest
post-minimization canonical run ... 18 @ a4f07ea
pre-removal reference run ......... 11 @ 783bc5a
removal commit .................... 913df97
review reference .................. 6a6687c (frozen, never moved)
```

**What is established, at four levels.**

1. **Empirical.** The dummy interface and the manual flake-input restore were
   deleted with no change to any observable §17 pre-registered, on both tested
   Nix versions, including a `closureSha256` identical to the pre-removal run's.

2. **Causal, scoped.** Their absence is compatible with the same confirmed
   behaviour `E1`–`E3` observed while they were merely disabled. **In the tested
   configuration**, these mechanisms are not necessary for the observed result.
   Not "Nix never needs them" — two CI jobs do not license that.

3. **Regression.** The removal deleted a region of state space in which a
   regression could exist unexamined. `t07`, `t15` and `t16` now exercise the
   validated configuration with no bypass switch, so a future Nix that
   reinstates the old behaviour turns the ordinary suite red. Minimization
   raised the falsifiability of the system, not only its tidiness.

4. **Methodological.** The series produced **five implementation defects, six
   measurement defects, and one sampling-design failure** — and the last round
   is the one that matters, because the rules worked *prospectively* rather than
   only explaining past crashes:

   * `t07.9` — a pre-registered criterion caught an assertion that was, in
     substance, `0 == 0`;
   * `t07.9a` — the first real run immediately refuted an over-strong model
     (`4/4`);
   * §17 — an acceptance criterion was found unsatisfiable **before** the causal
     intervention, so it could not afterwards be declared "roughly what we
     meant".

   ```
   bad instrument
       -> explicit falsifying-trace requirement
       -> instrument fails qualification
       -> claim corrected before measurement
       -> intervention only once the criterion is coherent
       -> REMOVAL_VALIDATED
   ```

   Until this round, §16a was open to the charge of being post-hoc wisdom:
   *six crashes, then a rule explaining the crashes*. It is not any more. The
   rule stopped the next instrument defect from becoming an experimental
   conclusion.

**A run is not automatically an experiment.** Pushing a documentation commit
triggers CI, and that execution is *operational verification* — it confirms the
tree still builds. It is not a new empirical claim and it is not indexed as an
experimental run. Without that distinction `evidence-runs.json` becomes a
graveyard of identical green executions where the numbers grow and the
knowledge does not.

The rules themselves are now in **`EXPERIMENT-PROTOCOL.md`**, deliberately with
no Nix in them, because that is the portable artefact. The funny part of the
whole exercise: this repository set out to demonstrate properties of a source
escrow, and the most transferable thing it produced is a rule about how not to
build a test that is only capable of agreeing with its author.

---

## 19. Pre-registration: an observation failure is not an observation

Written **before** the fix and before the run that judges it, per §17 and
`EXPERIMENT-PROTOCOL.md` §4. This opens a new line: §18 closed the previous one,
and this has its own claim and its own red traces.

### The claim under test

> **Store observation failures cannot be represented as source absence, and
> stage-internal observation failures cannot produce a successful evidence
> verdict.**

### Why this is a stop-the-line defect and not a bug report

Two mechanisms that exist to make the evidence trustworthy can currently turn an
**environment failure** into a **substantive conclusion**. For an ordinary
utility that is unpleasant. For a tool whose entire output is a claim about what
was demonstrated, it is disqualifying: a proof tool that reads HTTP 503 as
proven absence cannot be put in front of an auditor, and one such branch cancels
a great deal of correct work around it.

**P0-A — `nse_store_present` is a binary predicate over a three-valued
observation.** Today:

```
store says PRESENT   -> present
store says null      -> absent          (correct, fixed in run 7)
store request FAILS  -> absent          (wrong, and invisible)
```

`nix path-info --json` signals absence documentedly, as `null` with exit 0.
A **non-zero exit therefore cannot mean absence** — there is no room for
interpretation. The per-path fallback silently drops any path whose query
failed, so an unreachable, unauthenticated, throttled or 503-ing tier reports
every candidate absent and the run continues into a confident
`tier provided 0 of N`. The `file://` branch has the same shape: a store
directory that does not exist reads as a cache that holds nothing.

The correct model is not a predicate but an observation with three outcomes:

```
present                          -> PRESENT
successful negative observation  -> ABSENT
failed observation               -> UNKNOWN / ERROR   (never ABSENT)
```

**P0-B — the orchestrator disables `errexit` inside every stage it runs.**
`nse_verify || { rc=$?; …; }` places the whole function body in a context where
`-e` is ignored, so a failing command inside it does not abort. Measured on
bash 5.2.21, and two of the three obvious repairs do **not** work:

```
rc=0; stage || rc=$?            -> body continues after `false`   (the bug)
rc=0; ( stage ) || rc=$?        -> body continues after `false`   (suspension
                                   propagates into the subshell)
rc=0; ( set -e; stage ) || rc=$? -> body continues after `false`  (an explicit
                                   re-arm does NOT restore it)
rc=0; bash -c '… stage' || rc=$? -> aborts at `false`             (only this)
```

Only a **separate process** restores the semantics the code was written under.
That is measured, not read off a manual page — the third form is the workaround
usually recommended, and it does not work here.

The reachable consequence: `jq … > "$work/verify-escrow-set.txt"` fails, the
file exists and is empty, `n_escrow = 0`, `total = 0`, `missing = 0`, and the
report says `OBJECTS_PRESENT=0/0` and `ESCROW_VERIFY=PASS`. That is a textbook
specimen of this repository's own §16 — a tool containing the methodology that
explains why its own code is inadmissible.

### The intervention

1. `nse_store_present` gets a **contract**, enforced at the API boundary rather
   than left to callers: exit `0` means *the observation completed for every
   path asked about*; non-zero means *incomplete*, and the caller may not read
   its output as a complete presence set nor a missing path as absent. All nine
   call sites are audited against it. The one that matters most is the tier
   re-query in `nse_tier_materialise`: a failed re-query must not be recorded as
   a revised absence, which is precisely how an outage gets laundered.
2. Each pipeline stage runs in a **child process**, so `errexit` holds inside it
   and the orchestrator still sees only the final status.
3. **Measurement validity is established before measurement result**, and
   independently of shell mechanics:

   ```
   MANIFEST_READABLE = yes
   EXPECTED_OBJECTS  = 874          # pre-registered, non-empty
   OBSERVATION_OK    = yes
   -----------------------------------------
   only then:  OBJECTS_PRESENT = …   ESCROW_VERIFY = PASS|FAIL
   ```

   An expected set that is empty, or an extraction that did not succeed, is a
   `FAIL`/`HARNESS_ERROR` before any coverage is computed. A future shell trick
   must not be able to turn "could not obtain the data" into `0`.

### The red traces, defined in advance

Neither of these is satisfied by fixing an exit code alone. Both assert
**attribution**, because the central lesson of the previous line was that a
producer failure must not be reported as an observed absence — and a report that
blames the wrong suspect is still wrong after the status code is right.

```
RED TRACE 1 -- binary tier answers HTTP 503

  required:   BINARY_TIER_ERROR  (or HARNESS_ERROR), naming the tier
  forbidden:  "tier provided 0 of N"
              any SOURCE_ORIGIN_INDEPENDENCE failure attributed to the escrow
              any ESCROW_REPLAY verdict of the form "held 0 of N"

RED TRACE 2 -- the closure/extraction pipeline fails before producing an
               observation

  required:   ESCROW_VERIFY=FAIL or HARNESS_ERROR, naming the unreadable input
  forbidden:  OBJECTS_PRESENT=0/0 with ESCROW_VERIFY=PASS
              any PASS whose coverage was computed over an empty expected set
```

If either forbidden line appears, the fix has not been made, whatever the exit
codes say.

### The standing invariant

Stronger than the claim above, and kept **separate from `t21`/`t22`** on
purpose: those two tests are today's enforcement, and later probes and stages
will need their own. The rule outlives them.

> **No negative claim about source presence may be derived from an incomplete
> store observation, and no evidence verdict may be derived from an invalid
> measurement.**

Two failure modes it forbids, which are not the same thing:

```
UNKNOWN -> ABSENT                     a measurement failure becomes a fact
UNKNOWN -> ABSENT -> MAY_REBUILD      a measurement failure becomes a POLICY
                                      DECISION
```

The second is what `nse_tier_materialise` was doing, and it is the worse of the
two by a distance. A wrong report is wrong. A wrong report that then authorises
the acceptance build to rebuild an object it was supposed to receive from an
approved tier is a measurement failure steering an action. The permitted shape
is `UNKNOWN -> STOP`: exactly one of the three re-query outcomes may change
state, and it is the one where the store actually answered.

Any new probe, stage or verdict added to this tool is subject to this
invariant, and the qualification question for each is the one in
`EXPERIMENT-PROTOCOL.md` §1: what observable trace makes it refuse?

### What this run is not

It is not a re-run of anything in §18. That line is closed, its canonical run is
18 @ `a4f07ea`, and this does not reopen it: the observables §17 pre-registered
must still hold, but they are a *regression floor* here, not the result. The
result is whether the two red traces above appear.

---

## 20. Pre-registration: a non-sha256 source, and the observables it is expected to move

Written **before** the run. §19's intervention left the regression floor from
run 18 intact on purpose. This one does not, and says so in advance, because
the alternative is discovering a moved `closureSha256` after the fact and
reaching for an explanation.

### Why the fixture has to change

Every fixed-output source in the fixture is `sha256`. A cross-version
compatibility suite over that fixture only ever exercised the subset of the
derivation format where the two Nix versions happen to agree — and `nse_to_sri`
defaulted a bare digest to `sha256`, so **nothing in the fixture could have
noticed**. That is the sampling failure of §15a repeating: a sample that cannot
exhibit the difference under investigation.

`fetchurl` of `hello-2.12.1.tar.gz.sig` with a `sha512` SRI hash is added. A
different URL on purpose: sources #2–#4 make the `postFetch` argument by
sharing one URL and differing in exactly one attribute each, and a fourth
member would destroy that.

The bytes were fetched and both digests computed here. The `sha256` of the
tarball came out **identical to the hash already in the fixture**, which is how
the `sha512` beside it is known to be a digest of the right bytes rather than
an asserted constant.

### Observables expected to move, with the values

```
FOD_SOURCES                     165 -> 166
COVERED                         163 -> 164
HASH_MODE_FLAT                  159 -> 160
SOURCES_REQUIRED_BY_PLAN          4 -> 5
SOURCES_PRESERVED                 4 -> 5
CONTENT_IDENTITY_VERIFIED         4 -> 5
OBJECTS_REALISED                874 -> 875        (one new store path)
closureSha256                   CHANGES
```

### Observables expected NOT to move

```
EXTERNAL_RECOVERY                 2      the new source has an origin URL
WITH_POSTFETCH                    3      a plain fetchurl adds none
ON_KNOWN_FORGE                   38      ftp.gnu.org is not in the forge list
HASH_MODE_NAR                     6
derivations                     638 -> 639 is acceptable; a larger jump is not
SOURCES_DISCOVERED_NOT_REQUIRED_BY_PLAN  161
FLAKE_INPUTS                      4      no new flake input
t10.1 "exactly three sources share one identical upstream URL"  still THREE
```

`closureSha256` moving is legitimate **here** and was illegitimate in §17,
and the difference is the whole point of naming it in advance: §17's change
touched the acceptance harness and had no path to the fixture's derivation
graph, while this one adds a source to that graph. A hash that moves for a
stated reason is evidence; a hash that moves and then acquires a reason is not.

### The red outcomes

| observation | reading |
|---|---|
| `t10.1` no longer finds exactly three | the new source landed in the shared-URL set; wrong URL chosen |
| `ON_KNOWN_FORGE` moves | the forge classifier is matching something it should not |
| any source has `expectedHashAlgo = null` | discovery could not read the algorithm from this Nix's document, and `t01.8` fails rather than verify assuming one |
| `EXTERNAL_RECOVERY` moves | the new source's origin URL was not read |
| the two Nix versions disagree on any of the above | the algorithm is carried differently between schemas, which is exactly what this fixture exists to expose |

The last row is the one worth running for. If the versions disagree here, the
compatibility claim from run 18 was resting on a sample that could not have
shown a difference.

### 19a. Verdict on §19, and the cost of a refusal

**Both red traces appeared exactly as pre-registered.** Run 22, commit
`8d0a725`, both Nix versions: `unit-shell` 113/0, `flake check` pass,
`t00`–`t22` **161/0**, with every forbidden string absent.

```
t21.2  the run refuses rather than reporting a coverage figure          PASS
t21.3  and says the observation failed, naming the store                PASS
t21.4  it never reports the tier as holding 0 of N                      PASS
t21.5  and never calls anything absent on an unanswered question        PASS
t21.6  no manifest is written from an observation that did not complete PASS
t22.1-9  unreadable and zero-object closures refused; 0/0 never reported;
         positive control still verifies                                PASS
```

The §18 regression floor is intact — `165/163/2/3/38`, 638 derivations, 874
objects, `closureSha256 = 9243083e…f8ec` — and the report carries
`MEASUREMENT_VALIDITY=closure readable, expected objects 874, observation
complete`.

**And the run found a defect the pre-registration did not think to forbid.**

```
t21.1  the 503 tier is serving      09:56:14
t21.2  the run refuses              10:13:30      <- 17 minutes 16 seconds
```

One `preserve` against a store answering 503 took **seventeen minutes** to give
up. The whole suite went from ~2.5 minutes to 20, and 17 of those were one
command. The cause is the fix from §19 itself: on a batch failure the sweep asks
Nix about each of 227 objects individually, and Nix retries each with its own
backoff.

The semantics were right and the **cost of the refusal was never measured**. In
production that is a tool which, when the approved tier goes down, hangs for a
quarter of an hour before saying so — and an operator watching it has no way to
tell a slow refusal from a hang.

So the sweep now stops after `NSE_OBSERVE_GIVEUP` (default 5) **consecutive**
silences: a store that has answered nothing five times in a row is not
answering, and the remaining 222 questions add no information. The counter is
consecutive, so one unanswerable object among healthy ones still gets isolated
individually — `u19.3`/`u19.4` assert exactly that, because a cutoff that gave
up on the first failure would be a different and worse tool. The evidence
records both numbers: how many paths did not answer, and how many were never
asked.

**The rule this adds**, and it is now in `EXPERIMENT-PROTOCOL.md` §1:

> Ask not only what makes the check go red, but what a red one **costs**. A
> refusal nobody can afford to wait for is a refusal that will be worked around.

§16a's question — *what observable trace makes this refuse?* — was answered here
and the answer was correct. It simply never asked how long the answer takes,
and a seventeen-minute correct answer is a defect of its own.

### 19b. Instrument seven: a guard that passed because a sentence wrapped

`t21.5` — *never calls anything absent on an unanswered question* — passed in
run 22 and failed in run 24. The code between them did not change what it
claims. The **sentence re-flowed**:

```
run 22   "...which is not the same as answering that it does not
          hold them."                        grep -c 'does not hold'  ->  0   PASS

run 24   "...is not the same as answering that it does not hold them."
                                             grep -c 'does not hold'  ->  1   FAIL
```

A line-oriented grep cannot see a phrase split across a wrap, so the guard
passed for a reason with no connection to the property. It is the seventh
instrument in this project capable of passing by accident, and the same family
as `u14.3` and `t07.9`: a check whose green has a cause other than the thing it
is checking.

Two corrections, both **tightening**:

* The forbidden-phrase guards flatten the file (`tr '\n' ' '`) before matching,
  so a wrap cannot hide anything. `t21.4`, `t21.5`, `t22.3`, `t22.4`, `t22.7`.
* The refusal messages no longer utter the phrases they deny. That is worth
  stating as a rule on its own, because the grep is deliberately crude and will
  stay crude:

  > **A refusal message must not contain the words of the claim it is refusing
  > to make.** A sentence that denies a claim looks, to any text search, exactly
  > like one that makes it. State what is known, positively; let the negation
  > live in the documentation.

  `nse_store_present`'s warning now says *"an unanswered question yields no
  information about this store's contents"* rather than explaining what it is
  not saying, and `nse_tier_materialise` no longer quotes the label it refuses
  to apply.

Note which way this was resolved. The tempting repair was to loosen the pattern
so the denial stops matching; that would have made the guard blind to the real
thing it exists for. A forbidden-string check should fail on ambiguity and make
a human look. False positives there are cheap; false negatives are how this
project lost six months.

### 20a. Verdict on §20, including a miss

Run 24, commit `e301123`, both Nix versions. Every pre-registered move happened,
every pre-registered non-move held, **and the two versions agree on all of it**:

```
                              predicted   2.34.7   2.24.9
FOD_SOURCES                   166         166      166
COVERED                       164         164      164
HASH_MODE_FLAT                160         160      160
HASH_MODE_NAR                 6           6        6
SOURCES_REQUIRED_BY_PLAN      5           5        5
SOURCES_PRESERVED             5           5        5
CONTENT_IDENTITY_VERIFIED     5           5        5
EXTERNAL_RECOVERY             2           2        2
WITH_POSTFETCH                3           3        3
ON_KNOWN_FORGE                38          38       38
FLAKE_INPUTS                  4           4        4
derivations                   639         639      639
closureSha256                 changes     7f141ef1…  7f141ef1…  (identical)
t10.1 shared-URL sources      three       three    three
OBJECTS_REALISED              875         876      876      <- MISS
```

**The miss is recorded as a miss.** `OBJECTS_REALISED` was predicted to rise by
one and rose by two. One new fixed-output source added two paths to the realised
closure, and *why* is not established — writing a plausible mechanism here would
be exactly the move §17 forbids. It is a small, bounded discrepancy in a number
that was expected to move at all, and it is open.

**What the fixture bought.** The probe answers the question it was added for,
and the two schemas do differ:

```
2.34.7   outputs.out = { hash: "sha256-SaVxnAzFoHLjT/95…", method }
                        SRI: the algorithm is IN the hash, hashAlgo absent

2.24.9   outputs.out = { hash: "49a5719c0cc5a072e34fff79…",
                         hashAlgo: "sha256", method, path }
                        bare hex: the algorithm is a SEPARATE key
```

So on 2.24.9 `expectedHash` was a bare digest with no algorithm recorded
anywhere the code looked, and `nse_to_sri` supplied `sha256` from its default.
For the sha256 sources that guess was accidentally right, which is why nothing
ever noticed. **A sha512 source on 2.24.9 is a 128-character hex digest that the
old code would have handed to `nix hash convert --hash-algo sha256`.** The
fixture that could have exposed this did not exist until this commit, and the
fix landed one commit before it would have bitten.

`env.outputHashAlgo` is *empty* for one of the two sampled derivations on both
versions, so the `env` fallback alone would not have covered it —
`outputs[].hashAlgo` is the load-bearing source on 2.24.9. Both probes report
`fixed-output derivations whose algorithm is stated NOWHERE we look: 0`.

**And the cut-off works.** `t21.1` 10:25:40 → `t21.2` 10:26:18: **38 seconds**,
against 17 minutes 16 seconds in run 22.

The compatibility conclusion from run 18 rested on a sample that could not have
shown this difference. It can now, the difference is real, the tool reads both
forms, and the observables still agree.

### 20b. gap-23 was arithmetic, and the answer was in the same report

Closed. `OBJECTS_REALISED` is `nix-store --query --requisites --include-outputs`
of the top derivation, and that set **contains the `.drv` files themselves** —
`t15.13` says so in as many words. One added fixed-output source therefore adds
**two** store objects:

```
+1   the .drv                     text-CA
+1   its output                   fixed-CA
---
+2   OBJECTS_REALISED   874 -> 876
```

Both land in the content-addressed bucket, which is why the same report shows
`ESCROW_OBJECTS_CONTENT_ADDRESSED` 820 → 822 with `SIGNATURE_ONLY` and
`UNSIGNED_INPUT_ADDRESSED` unmoved, and `DERIVATION_DOCUMENT` 638 → 639
derivations. Three numbers, all printed within a few lines of the one that was
called unexplained, all consistent with +2.

§20 predicted +1 because it forgot that a derivation is itself a store object —
and predicted the derivation count in the same table without joining the two
rows. Opening a gap for it was the wrong call twice over: the arithmetic is
undergraduate, and the evidence was already on the page.

**The rule this earns**, and it is narrower and more useful than "measure, do
not guess":

> Before opening a finding for an unexplained number, check whether the same
> report already explains it. A registry that carries open questions with
> visible answers is a registry nobody will trust to be current.

`t03` now asserts the relationship rather than leaving it to arithmetic done
after the fact: the count of `.drv` paths in the realised set equals the
derivation count discovery recorded, so a future divergence between the two is
a red test rather than a mystery in a table.

### 20c. A syntax check is not an execution check

Run 27 (`0d4ae1e`) died 74 seconds in:

```
tests/run-tests.sh: line 28: $2: unbound variable
```

Line 28 is `assert_eq`. An edit inserted `t03.9` between
`assert_eq "t03.1 …" \` and its arguments, so `t03.1` became a one-argument call
and its arguments were orphaned on the line below. The file remained
**syntactically valid**, `bash -n` reported ok, `shellcheck` reported ok, and
this machine has no Nix, so the only thing that could execute the suite was CI.

The honest statement of a standing limitation: for `tests/run-tests.sh`, "checked
locally" has only ever meant *parsed* locally. That is a weaker claim than the
one made for `tests/unit-shell.sh`, which is genuinely executed here, and the
difference had not been written down.

`u23` is the cheapest thing that closes it without Nix: it joins line
continuations and requires every `assert_eq` / `assert_ne` to still carry an
argument after its label, and flags an orphaned argument line. `u23.2` proves
the check goes red on a stripped assertion, because a checker nobody has seen
fail is not a checker — the lesson of `u20.8`, applied on the same day it was
learned.

Added to `EXPERIMENT-PROTOCOL.md`'s checklist as its own line:

> I have EXECUTED it, not merely parsed it.

### 20d. Verdict on run 28, and instrument nine: the test that measured its own error message

Run 28 (`1ae0b1c`), both Nix versions, **unit-shell 147/0, flake check pass,
acceptance 170/3** — and the three reds are all in one test, `t23`, which is the
instrument and not the subject.

Everything else the run was asked to settle came back green:

| claim | verdict |
| --- | --- |
| `t03.1` repaired, called with its arguments | green |
| `t03.9` the realised set holds exactly one `.drv` per discovered derivation | **green** |
| `t22.5a`–`t22.5d` a refusal is recorded as `HARNESS_ERROR`, names the unmet prerequisite, fabricates no coverage, and does not read as `NOT_RUN` | green |
| every §20 observable unchanged from run 24 | green |

`t03.9` green is the one that matters most, because it was the falsifiable half
of §20b. **gap-23 stays closed on measurement rather than on argument.** The
observables are identical on both legs and identical to run 24: 166 / 164 / 2 /
3 / 38, 160 flat + 6 nar, 639 derivations, 876 objects,
`closureSha256 = 7f141ef1…ecb2`.

#### The instrument defect

```
FAIL t23.1 the run completes with a credential supplied     expected '0', got '1'
PASS t23.2 the sentinel appears in NOTHING the CI job uploads
FAIL t23.3 the evidence records only that a config was supplied   expected 'yes', got ''
PASS t23.4 the 0600 carrier file is gone when the run ends
FAIL t23.5 positive control: the sentinel did reach the run  expected something other than '0'
```

`t23` created a fresh **empty** directory and handed it to
`test-origin-independence` as `--escrow-dir`. `prove` *reads* an escrow; it does
not create one. It died on the missing `manifest.json` before it ever reached
the credential path, so the sentinel was never in play — and `t23.2`, the
assertion the whole test exists for, was a grep over a run that had not begun.
`t23.4` passed for the same empty reason: a carrier file that was never written
is also absent at the end.

So run 28 established **nothing whatever about the secret-handling code, in
either direction.** Every other test with a custom `--escrow-dir` — `t08`,
`t16`, `t18` — copies `manifest.json`, `closure.json` and `discovery.json` in
first. `t23` was written without that step and its author did not notice,
because two of its four assertions pass when the run does not happen.

#### What caught it

`t23.5`, the positive control, and only that. This is the ninth check in this
project able to pass by accident, and the first one where the guard against that
class **worked as designed and named the fault the same minute**. The reason it
was needed is worth stating on its own, because it generalises past this test:

> A credential that is correctly redacted and a credential that never arrived
> look **identical** from outside. Any test whose subject is an absence must
> separately establish that the thing was present to be absent from.

#### Both corrections

`t23` now builds a real escrow the way `t16` does, and **arrival is measured
separately, in its own run**, because run A cannot prove its own premise. Run B
supplies an unknown setting name, which Nix repeats back verbatim; nothing
asserts run B's exit status, since a warning and a refusal both quote the
fragment and either one proves the file crossed into the namespace. `t23.6` then
requires that even a fragment Nix shouts about is still not serialised into
`prove-env.sh`.

And the run exposed a second, quieter fail-open in the escape hatch itself. The
inner script read the carrier with

```
$([ -n "$NSE_EXTRA_NIX_CONFIG_FILE" ] && [ -r "$NSE_EXTRA_NIX_CONFIG_FILE" ] && cat …)
```

An unreadable carrier collapsed to the empty string and **the run continued
without the credential** — this repository's own missing-is-not-empty, one more
time, in the one place where the consequence is an operator debugging their
authenticated tier instead of the tool that dropped the fragment. A fragment
that was supplied and did not arrive is now a refusal (`exit 91`) naming the
file and never its contents. `u21.6`–`u21.8` guard it, and `u21.6` was driven
red against a copy with the old construction restored before being trusted.

## 21. Pre-registration: a binary tier Nix will not trust

`ESCROW_OBJECTS_UNSIGNED_INPUT_ADDRESSED=1` has been in the report for eighteen
runs. The signature policy around it — *this tool will not disable signature
checking for an ordinary binary tier on the operator's behalf* — has been
**stated in a refusal message and never once executed.** §20d's rule applies to
policies as much as to tests: an unexercised branch is a claim, not a behaviour.

### The claim

> A binary tier whose objects Nix will not accept produces `SIGNATURE_UNTRUSTED`,
> naming the object and quoting what Nix said, and never an absence, an outage,
> or a quietly weakened trust policy. Supplying the tier's public key — and only
> that — turns the same run green.

### The design is paired, and that is not decoration

Legs B and C use **the same tier, the same object, and differ in exactly one
variable**: whether the tier's public key is trusted.

| leg | tier | key trusted | required outcome |
| --- | --- | --- | --- |
| A | object unsigned | — | refuse, `SIGNATURE_UNTRUSTED` |
| B | object signed by a generated key | no | refuse, `SIGNATURE_UNTRUSTED` |
| C | **the same signed tier** | **yes** | **succeed, object in the replica** |

Without C, every assertion in `t24` is satisfied by a tool that refuses
everything — which is a worse tool, not a better one, and would read as a pass.
This is `t23`'s lesson stated as a construction rather than as a regret.

`t24.3` and `t24.4` are preconditions and not decoration: if the "signed" tier
carries no `Sig:` line, C would succeed for a reason unconnected to the key and
B would refuse for leg A's reason. The vehicle is **input-addressed** — chosen by
the absence of a `CA:` line — because a content-addressed object is accepted on
its hash whatever its signature, and picking one would make the whole test
vacuous by construction.

### The red outcomes, classified in advance

- **A or B green** — the tier copy is not checking signatures at all. That is
  the policy failing, and the fix is in `lib/preserve.sh`, never in `t24`.
- **C red** — the escape hatch does not deliver `trusted-public-keys` to the
  tier copy, or the refusal is not attributable to the key. Either way the
  paired design is broken and A/B prove nothing.
- **t24.9 or t24.10 red** — a trust refusal was laundered into an absence. That
  is the `UNKNOWN → ABSENT → MAY_REBUILD` defect of §19, one store over.
- **t24.13 or u24.2 red** — the tool added `--no-check-sigs` to get past its own
  refusal, i.e. weakened the operator's trust policy for the convenience of a
  test.
- **t24.1 or t24.2 red** — the fixture could not be built. The test measured
  nothing; it must not be reported as evidence in either direction.

`u24` is the static half, and it exists because a red `t24` has one
character-cheap wrong fix. It is scoped to `nse_tier_materialise` — staging and
host copies legitimately use `--no-check-sigs`, since those read stores this tool
has just written — and `u24.3` drives the guard red against a doctored copy
before it is trusted.

### What this does not establish

Nothing about a real authenticated tier. The keys are generated locally, the
tier is a `file://` directory, and no credential crosses a network. `gap-22`
stays open, and so does the S3/Attic item.

### 21a. Run 30: the fixture was signed by a key everyone trusts

Run 30 (`d299c63`), both Nix versions: **unit-shell 155/0, acceptance 185/7**,
all seven reds in `t24`, and `t23.1`–`t23.6`, `t03.9` and every §20 observable
green and unchanged.

```
PASS t24.3 the signed tier really carries signatures
FAIL t24.4 and the unsigned tier really carries none    expected '0', got '6'
FAIL t24.5 an unsigned tier object is refused, not accepted
FAIL t24.6 and the refusal is SIGNATURE_UNTRUSTED
FAIL t24.8 and quotes what Nix actually said about the signature
FAIL t24.10 and no manifest is written from a refused materialisation
FAIL t24.11 a signature by an unknown key is refused too
FAIL t24.12 also as SIGNATURE_UNTRUSTED
```

§21 classified "leg A or B green" as **the policy failing, fix `preserve.sh`,
never the test.** That classification is wrong here, and the thing that says so
is `t24.4`: *the unsigned tier carried six `Sig:` lines.*

The fixture copied the victim out of the **host store**, where every object that
had been substituted from `cache.nixos.org` still carries that cache's signature
in the store database. `nix copy` propagates it. So the "unsigned" tier arrived
signed by a key that is **trusted by default**, and:

- leg A was accepted because the object was legitimately trusted — correct
  behaviour for what the fixture actually was;
- leg B was accepted for the same reason, my generated key never mattered;
- **leg C succeeded for a reason unconnected to the key**, so the one assertion
  the paired design rests on was as hollow as the rest.

`t24.10` and `t24.12` are downstream of that: a run that does not refuse writes a
manifest and quotes no signature error. `t24.7` and `t24.9` *passed* — vacuously,
on a successful run.

**So the policy is still untested.** Run 30 did not show the tier path checks
signatures and did not show it doesn't. A green leg A is consistent with both,
which is precisely why the pre-registration's classification could not be
applied as written: it assumed the fixture was what it claimed.

#### The correction

The tiers are now built from a **signature-free copy of the escrow cache**, made
by *removing* the `Sig:` lines rather than by hoping there are none, with both
tiers copied from that same source — one left alone, one signed by the generated
key. `t24.1` asserts the stripped cache has no signatures left, `t24.5` that the
unsigned tier has none, `t24.6` that it is not simply empty, and `t24.4` that the
signed one does. Four preconditions before a single behavioural claim, because
this is now the second consecutive test in this project whose fixture, not whose
subject, was the thing that was wrong.

`t24.9` no longer requires the refusal to name one specific path — Nix may refuse
on any member of the victim's closure — but requires the named path to be one the
tier **actually holds**, checked against its narinfos.

Also fixed: a `find | sort` feeding a loop that breaks early left `sort` writing
into a closed pipe (`sort: write failed: Broken pipe` in the run 30 log). Harmless
inside process substitution, and the same shape that once took an entire run down
from inside a pipeline. It writes to a file first now.

#### The rule this adds

> A precondition that has never been observed to fail is not a precondition. When
> a test's fixture is built out of the system under test's own materials, state
> what the fixture must NOT contain and assert that too — the defaults of the
> surrounding system are not neutral.

### 21b. Run 31: the suite died between the header and the first assertion

Run 31 (`65a81dd`), both Nix versions. **`nix flake check` red for the first time
in thirty-one runs**, and the acceptance suite ended here:

```
t24  an untrusted tier signature is a TRUST refusal, and a key makes it work
##[error]Process completed with exit code 1.
```

The header printed. **Not one t24 assertion ran.** So for the second consecutive
run, nothing whatever is established about the binary-tier signature policy —
and this time the fault was not even in the fixture, it was in the line that
checks the fixture:

```
stray=$(grep -l '^Sig: ' "$STRIP"/*.narinfo 2>/dev/null | wc -l)
```

`grep` exits 1 when it finds nothing. `pipefail` hands that to the pipeline, and
a **variable assignment takes its substitution's status**, so `set -e` ended the
run. The line was asserting that the stripped cache had no signatures left,
which means **the success case was the fatal one**: the better the fixture, the
harder the suite died. Same shape as the `find | head` that took down run 7.

The distinction that makes this tractable, and that keeps the new guard small:

> A command substitution in an **argument** — `assert_eq "…" "$(grep -c …)"` —
> does not set the calling command's status and is safe. One in an
> **assignment** does.

`u25` flags only assignments, joins line continuations first, and `u25.2` drives
it red against the exact line that killed run 31. Auditing for that shape found
one more live instance — `u20.9`'s `rendered=$(grep -oE … | tr | sort)`, which
would have killed `unit-shell.sh` on the day `EVIDENCE.md` rendered no gap rows.

#### And the flake check found what a local run reported as inconclusive

Two INFO-level findings, `SC2012` and `SC2016`. Before pushing I ran shellcheck
here — **without the flake's flags** — got a non-zero exit from unrelated
`SC1091` notices, and reported the result as unavailable rather than as a
finding. The repository's real invocation is one line in `flake.nix`:

```
shellcheck -x -e SC1091 --shell=bash bin/nix-source-escrow lib/*.sh tests/*.sh
```

`u26` runs exactly that, here, with `u26.2` as its positive control. Writing
`u26` immediately turned `u26.1` red on the code written alongside it, which is
the shortest gap yet between a check appearing and catching something. Its
control needed one correction of its own: `echo $x` after a constant assignment
is **not** flagged by shellcheck 0.11, so the specimen is an `SC2016` — a
finding this exact shellcheck was observed to emit — and it is assembled from
pieces so that writing the control does not trip `u26.1`.

#### The standing cost, stated plainly

`t24` has now consumed **two CI runs and established nothing**: run 30 measured a
fixture that carried a trusted signature, run 31 never reached an assertion. Both
faults are mechanical, both were invisible to `bash -n`, and both are the direct
consequence of the limitation in §20c — the acceptance suite cannot be executed
on the machine that writes it. `u23`, `u25` and `u26` are what can be closed
statically. The rest is paid for one CI run at a time, and saying so is cheaper
than pretending the next push is obviously correct.

### 21c. Run 32: t24 finally executed, and it found two things

Run 32 (`9fc07e3`), both Nix versions. `nix flake check` **green** — `u26` did
its job. `unit-shell` 159/0. And `t24` ran end to end for the first time:
**186/8**.

The fixture preconditions are green, which is what makes the rest a measurement
rather than a rumour: `t24.1` the stripped cache has no signatures left, `t24.5`
the unsigned tier carries none, `t24.6` it is not simply empty.

#### Finding one: the signing mechanism had never worked

```
FAIL t24.4 the signed tier really carries signatures   expected something other than '0'
```

`secret-key-files` does **not** sign on a cache-to-cache `nix copy`. The signed
tier came back with zero `Sig:` lines.

Now read that against run 30, where the same precondition **passed**. It passed
on signatures that were `cache.nixos.org`'s, propagated out of the host store.
So the signing mechanism this test depends on had **never once worked**, in
either run, and the only reason anyone knows is that the precondition was
finally asked on a fixture with nothing to inherit.

Signing now goes through a local store — copy in, `nix store sign --store`, copy
out — and `t24.8` requires the signatures to be **by the key this test
generated**, not merely present. Counting `Sig:` lines is precisely what let run
30 through.

#### Finding two: with a verified-unsigned tier, preserve accepted the object

```
FAIL t24.11 an unsigned tier object is refused, not accepted
FAIL t24.16 and no manifest is written from a refused materialisation
```

This is §21's "leg A green" case, and this time on a fixture that has been
checked. An object carrying **no signature at all** was materialised out of the
binary tier and a manifest was written.

**The mechanism is not being asserted.** §17 forbids writing a plausible one, and
"the tool has no signature checking" and "Nix does not verify on this destination"
produce the same green leg. So run 33 measures it instead of guessing:

| probe | destination | required |
| --- | --- | --- |
| `t24.9` | a **local store**, `require-sigs = true` | must **refuse** — the control that signature checking is live here at all |
| `t24.10` | a **binary cache** directory, same config | **predicted to accept** |

The prediction is that verification lives in the local store's add path, so a
`file://` replica destination never verifies. If `t24.10` goes red the prediction
is wrong and `t24.11`'s cause is somewhere else entirely — which is the only
reason to write the prediction down before the run rather than after it.

`preserve.sh` is **not** being changed yet. If the probe says the destination is
the mechanism, the fix is a design decision — materialise through a store that
verifies, rather than making the existing copy try harder — and that choice
should be made with the answer in hand, not with a hypothesis. `gap-25` records
the open question.

#### The state of the claim

The binary-tier signature policy is still **not established**, three runs in. But
the reds have changed character: runs 30 and 31 were harness faults that measured
nothing, and run 32's are findings. That is a different kind of red and it is
worth saying so.

### 21d. Run 33: the probe answered, and the refusal branch was unreachable

Run 33 (`b11d627`), both Nix versions. `nix flake check` green, `unit-shell`
159/0, acceptance **191/7**, and every fixture precondition is green for the
first time — including `t24.8`, the signatures are by **the key this test
generated**, so the local-store signing route works where `secret-key-files` on a
cache-to-cache copy did not.

**The probe answered, and the pre-registered prediction holds exactly:**

```
PASS t24.9  control: Nix refuses an unsigned object into a LOCAL store
PASS t24.10 predicted: a BINARY CACHE destination does not verify
```

Same object, same `require-sigs = true`, same `trusted-public-keys`. The only
difference is the destination, and it decides the outcome. So signature
verification lives in the **local store's add path**, and a `file://` binary
cache accepts anything.

`nse_tier_materialise` copies the tier straight into the replica, which is a
`file://` binary cache. Therefore:

> **The `SIGNATURE_UNTRUSTED` branch was unreachable.** Not mis-worded, not
> mis-classified — it could not fire, because the copy it guards never checks.
> The policy this tool states in its own error message was, as written, a
> statement about a code path no input could reach.

That is the defect, and it is now attributed rather than guessed. `t24.11`–
`t24.14` and `t24.17`/`t24.18` are red because of it.

And it retroactively demotes the green half: `t24.20`–`t24.23` (leg C, key
supplied, object materialises) currently pass **trivially**, because everything
passes. Leg C becomes an attributable positive control only once legs A and B
can fail. Until the fix lands, no part of `t24` supports the policy claim.

#### The fix, and why this one

Materialise the tier **through a local store**, then push to the replica:

```
tier  --(nix copy, verifies signatures)-->  local temp store  --(--no-check-sigs)-->  replica
```

Chosen because `t24.9` **measured** that a local store destination enforces. The
tempting alternative — `nix store verify --sigs` against the tier, no second copy
— is cheaper and its flag spelling across Nix 2.24.9 and 2.34.7 has **not been
measured here**, and this project has now lost four runs to mechanisms that were
assumed rather than checked. It is recorded as `gap-26`, not adopted.

**The cost, stated rather than discovered later.** One extra *local* copy and a
transient second copy on disk of the tier objects being materialised. Downloads
from the tier are unchanged — still one — because the local store is the thing
that fetches. Peak disk rises by the size of the materialised set, released when
the temp store is removed.

#### Observables this must not move

The §20 set — `FOD_SOURCES` 166, `COVERED` 164, `EXTERNAL_RECOVERY` 2,
`WITH_POSTFETCH` 3, `ON_KNOWN_FORGE` 38, `HASH_MODE_FLAT` 160 / `NAR` 6, 639
derivations, 876 objects, `closureSha256 = 7f141ef1…ecb2` — and:

- `t20` a tier that claims an object then refuses it is still `BINARY_TIER_ERROR`,
  not a signature refusal. The new check must not swallow that classification.
- `t21` a tier answering 503 still refuses as an observation error, and still
  within seconds rather than minutes.
- `t15`/`t16` the ordinary `source-origin-independence` runs against
  `cache.nixos.org` stay green — its objects are signed by a default-trusted key,
  so the new hop must be transparent to them.

#### The red outcomes, classified in advance

- `t24.11` still green (unsigned still accepted) → the hop is not where the
  enforcement is either; do not add a third mechanism, find out why.
- `t20` or `t21` turning into `SIGNATURE_UNTRUSTED` → the new check is
  mis-attributing an outage as a trust decision, which is §19's laundering with
  the sign reversed.
- `t15`/`t16` red → ordinary tiers broke; the fix costs more than it buys.
