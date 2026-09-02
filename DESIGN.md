# DESIGN

Only decisions that were expensive to get right, or that a reader would
otherwise get wrong. Everything here was measured on the machine described in
`EVIDENCE.md`, not assumed.

---

## 1. Software Heritage is a repair backend, not a substituter

The tempting design is "add Software Heritage as a substituter and the problem
is solved". It is wrong, in two independent ways.

**SWH does not speak the binary-cache protocol.** There is no `narinfo`
endpoint. The real path is a multi-step recovery:

```
expected NAR hash
  -> GET /api/1/extid/nar-sha256/<base64url or hex>/     (ExtID lookup)
  -> SWHID (swh:1:dir:... or swh:1:cnt:...)
  -> POST /api/1/vault/flat/<swhid>/                     (asynchronous "cook")
  -> poll until the bundle is ready, download it
  -> reconstruct the tree
  -> re-apply whatever transformations the fetcher applied  (see §3)
  -> verify the expected Nix hash
  -> only then: put it in our escrow
```

Steps 3 and 4 are asynchronous and can take minutes. Step 6 is the hard one.
Nothing about this fits inside `substituters`.

**SWH stores the upstream representation, not the Nix output.** For a directory
ingested from a VCS origin, SWH holds the tree as upstream published it. The Nix
fixed-output hash frequently refers to a tree *after* unpacking, root-stripping
and `postFetch` — see §3. `nixpkgs-swh`'s `sources.json` carries a `postFetch`
field precisely because that information is not recoverable from the archived
object alone.

Consequence for v0.1: SWH stays an **explicit extension point**, not a
dependency. The escrow is the substituter; SWH would be a *repair* path that
runs when the escrow has a hole, writes its verified result **into** the escrow,
and is then never consulted again. Subsequent builds must not depend on SWH.

This is a design constraint, not a TODO: **we do not claim a working SWH bridge,
and the recovery model above is unverified in this repository.** Claiming
otherwise before §3 is solved would be dishonest.

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

**Why this blocks the SWH bridge.** Recovering "the upstream artefact" from SWH
and stopping there reconstructs none of these. A correct bridge has to replay
`unpackFile` + `stripRoot` + the caller's `postFetch` shell, in the same
`stdenv`, and then land on the same NAR hash. That is a build, not a download,
and it is version-sensitive. Until it is demonstrated end to end, no claim of
SWH recoverability should be made.

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

The fix in `prove.sh` is a `dummy0` interface inside the namespace with a
default route to `10.99.0.254`, an address that does not exist:

```
ip link add dummy0 type dummy
ip addr add 10.99.0.1/24 dev dummy0
ip route add default via 10.99.0.254 dev dummy0
```

Nix's heuristic is satisfied; nothing is reachable. The evidence records that:
every origin is probed both by name **and** by an address resolved *before*
entering the namespace, and the by-address probes time out (`curl` exit 28, no
route) rather than merely failing to resolve (`curl` exit 6).

Related: glibc NSS reaches `nscd`/`nsncd` over a **unix socket**, which a
network namespace does not isolate — so name resolution inside the namespace is
still answered by the host until you also enter a mount namespace and put a
tmpfs over `/run/nscd`. It cannot move bytes, but the evidence should not have
to rely on that argument, so the test does both.

---

## 9. Isolation mechanism, and what it does and does not prove

`unshare -Ur --net --mount`, unprivileged. Inside: loopback, the dummy device,
no route out, no NSS. The build runs against a **local store**
(`nix build --store <dir>`), which matters: a local store is served in-process,
so the namespace actually contains the fetching. Going through the
`nix-daemon` would not work — the daemon lives outside the namespace and would
happily fetch on our behalf.

Two Nix settings are needed because `unshare -Ur` maps us to uid 0 with a
single-entry uid map: `build-users-group = ` (empty, or Nix tries to chown the
store to `nixbld`) and `require-drop-supplementary-groups = false` (or
`setgroups` fails).

**What this proves:** the build completed with every origin — and
`cache.nixos.org` — unreachable, from a store that started empty, with a cold
fetcher and eval cache, producing the store path the manifest predicted.

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
* **Attic / a binary-cache server** — a directory is enough for the acceptance
  test, and a server would add infrastructure without changing the guarantee.

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
   third verdict; it can never be `PASS`, whatever the build did.
2. any origin reachable by name or by address → `FAIL`.
3. any origin that failed to resolve *before* isolation → `FAIL`. If we never
   learned its address, we cannot claim we proved it unreachable.
4. substituters not exactly the escrow → `FAIL`. Otherwise a green build would
   not tell us where the sources came from.
5. only then: evaluation, build, restored sources, output path, and zero
   http(s) fetches in the log.

Reporting follows the same rule. `ORIGIN_HOSTS_PROVEN_UNREACHABLE` is computed
from the probe results, so it lists what was demonstrated; the intended
blocklist is not printed as though it were a finding.

The general form of the mistake is worth naming, because it is easy to repeat:
**the tool that enforces "`UNKNOWN` never silently becomes `PASS`" is itself
subject to that rule.** Test `t12` now runs the two adversarial cases — a
control run, and a run that *claims* isolation while having none — and requires
both to refuse.
