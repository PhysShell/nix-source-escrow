# DESIGN

Only decisions that were expensive to get right, or that a reader would
otherwise get wrong. Everything about *this tool's behaviour* was measured on
the machine described in `EVIDENCE.md`, not assumed.

Two kinds of statement here are not measurements, and both are labelled where
they appear: figures quoted from upstream projects (§1), and hypotheses read
out of the Nix sources that this repository has not yet run (§8, §8a). The
second kind ships with an experiment — `tests/experiments.sh` — rather than
with a conclusion.

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

## 8. Gotcha: Nix disables *all* substituters when it thinks it is offline

This cost the most time, so it is written down.

Nix 2.34.7 prints `warning: you don't have Internet access; disabling some
network-dependent features` and then refuses to substitute **even from a
`file://` store on the local disk**:

```
error: path '/nix/store/...-stdenv-linux-no-cc' is required,
       but there is no substituter that can build it
```

The identical command, identical config, identical escrow, with a working
network, substitutes from that same `file://` cache without complaint. So a
naive air-gapped test fails for a reason that has nothing to do with whether the
escrow is complete — which is a great way to spend an afternoon debugging the
wrong thing.

**The workaround, and why it is gone.** The original fix was a `dummy0`
interface inside the namespace with a default route to an address that does not
exist, which satisfies the heuristic while reaching nothing. But the heuristic
in `src/nix/main.cc` is conditional:

```c++
if (!args.useNet) {
    // FIXME: should check for command line overrides only.
    if (!settings.getWorkerSettings().useSubstitutes.overridden)
        settings.getWorkerSettings().useSubstitutes = false;
}
```

It only disables substitution when `substitute` is *not* an explicit override.
`prove.sh` sets `substitute = true`, so the dummy interface should be dead
weight — and reading the source is not this repository's standard of evidence,
so it was left in place behind an experiment.

**The experiment ran. `E1 = CONFIRMED`, on Nix 2.34.7:**

```
E0 BASELINE_OK   the legacy workarounds still pass, so the variants are attributable
E1 CONFIRMED     no dummy interface        -> the acceptance test still passes
E2 CONFIRMED     no manual input restore   -> Nix substitutes locked inputs itself
E3 CONFIRMED     both dropped              -> what the tool now ships
```

So the dummy interface is **off by default**, and `--dummy-interface` turns it
back on. That flag is not vestigial politeness: the result is established for
**Nix 2.34.7 and for no other version until tested**. The same CI run measured
2.24.9 behaving differently enough elsewhere (§15) that assuming version
independence here would be exactly the habit this file exists to break.
`tests/experiments.sh` names both workarounds explicitly rather than relying on
the defaults, so it stays re-runnable on any Nix and answers the question
again rather than agreeing with itself.

**Setup is fail-closed now.** The `ip` commands ran unchecked under `set -uo
pipefail`. On a kernel with no `dummy` module the interface silently never
appeared, and the run came back `FAIL` with the reason *"build failed under
origin blackout"* — an accusation against the escrow for a fault in the
harness. Every isolation operation is now checked, and a failure produces a
distinct `HARNESS_ERROR` verdict that `--expect-fail` refuses to accept as a
negative control. Test `t14` forces it by putting a failing `ip` on `PATH`.

The evidence records what the isolation actually achieved either way: every
origin is probed both by name **and** by an address resolved *before* entering
the namespace, and the by-address probes time out (`curl` exit 28, no route)
rather than merely failing to resolve (`curl` exit 6).

Related: glibc NSS reaches `nscd`/`nsncd` over a **unix socket**, which a
network namespace does not isolate — so name resolution inside the namespace is
still answered by the host until you also enter a mount namespace and put a
tmpfs over `/run/nscd`. It cannot move bytes, but the evidence should not have
to rely on that argument, so the test does both. NSS isolation is *graded*
(`full`/`partial`), not fatal: the by-address probes are what carry the
argument, so a partial result is reported rather than treated as a harness
error.

---

## 8a. The flake-input restore proves the wrong thing

Before evaluating offline, `prove.sh` copies the locked flake input paths out
of the escrow into the test store. That was written on the assumption that a
locked input is re-fetched from its origin unless the store already holds it.

Nix 2.34.7 says otherwise. `Input::getAccessorUnchecked`:

```c++
/* The tree may already be in the Nix store, or it could be
   substituted ... So check that. */
if (isFinal() && getNarHash()) {
    auto storePath = computeStorePath(store);
    store.ensurePath(storePath);
    ...
}
```

The store path is computed from the lock's `narHash` and `ensurePath` will pull
it from a configured substituter. So the manual copy is not needed — and worse,
it changes what the test demonstrates:

```
what we want to prove              what the manual restore proves
---------------------------        ------------------------------
consumer with flake.lock           our bash script
  -> configured substituter          -> nix copy
  -> gets the input                  -> Nix finds it already in the store
```

Those are different claims, and only the first one is about a real consumer.

**`E2 = CONFIRMED` on Nix 2.34.7.** The manual copy is gone from the default
path; `--manual-input-restore` keeps it as the diagnostic of escrow contents it
was always good at. Same scope caveat as §8: measured on one Nix version, and
`tests/experiments.sh` is how you find out about yours.

---

## 9. Isolation mechanism, and what it does and does not prove

`unshare -Ur --net --mount`, unprivileged. Inside: loopback, optionally the
dummy device of §8, no route out, no NSS. Every one of those setup steps is
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

**Why the first one exists.** `ESCROW_REPLAY` costs a copy of the entire
realised closure — 874 objects and 87 MB for a fixture that consumes four
sources. Running that on every Renovate bump is not a gate, it is a tax. The
cheap mode escrows only the objects that have an origin to lose. What it proves
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
