# Policy-governed source escrow under an untrusted change proposal

A second experimental line in this repository. It branches from the frozen head
of the first (`84354e8`) and **does not modify it**: that line's
`evidence-runs.json`, `known-gaps.json`, `EVIDENCE.md` and history are the index
of a closed experiment and stay that way. This line has its own namespace, its
own run index, and its own tests.

* the contract: [`PREREG.md`](PREREG.md) — written before the code, amended in
  the open, with an amendments log
* the index: [`runs.json`](runs.json) — a run appears only if it measures a
  pre-registered claim

---

## The question

> Can an escrow-governed Nix project derive preservation obligations
> automatically from the dependency graph of an **untrusted** pull request, by
> applying a **trusted** declarative policy and a **trusted** judge, so that the
> pull request cannot weaken the governing policy, replace the governing judge,
> or hide a policy-relevant change behind an unchanged content hash?

The object of study is not an annotation syntax. It is:

> **Who is allowed to decide what must be preserved, when the proposed change
> itself is untrusted?**

Prove the authority boundary first. Only then is it worth giving the decision
credentials to durable storage.

## Four claims, and where they stand

| id | claim | status |
|---|---|---|
| **C1** | a candidate cannot weaken its governing policy | demonstrated by fixture A |
| **C2** | a candidate cannot replace its governing judge | demonstrated by fixture B |
| **C3** | a policy-relevant change cannot hide behind content equality | demonstrated by fixture D |
| **C4** | an annotation moves `.drv` identities, not realised outputs, and rebuilds nothing | measured on both Nix versions, run 2 |

Everything else in `PREREG.md` is mechanism, observable or supporting
assertion, and says which it is.

## The shape of it

```
TRUSTED ROOT                          UNTRUSTED CANDIDATE ROOT
  nix-source-escrow.toml                flake / source
  bin/nse-pg, lib/pg-*.sh               candidate config
  the policy schema                     candidate workflows
                                        candidate copy of the judge
        |                                       |
        |  policy, schema, judge                |  the dependency graph
        |                                       |  and nothing else
        v                                       v
                    nse-pg gate
                         |
   FACTS  ->  POLICY  ->  DECISION  ->  EVIDENCE
```

Four layers, kept apart, because conflating any two is how a green report gets
produced about nothing:

> Policy is not evidence.
> A discovery fact is not policy.
> A decision is not an observation.

The candidate's copy of the judge is **hashed and reported, never executed**. A
head workflow invoking `base/bin/...` is not enough, because the candidate can
edit the workflow that does the invoking — which is why the two roots are two
arguments to the gate rather than one root and a convention.

## Three axes, and annotations that can only strengthen

```
coverage    ignore  <  auto  <  required
retention   while-referenced  <  permanent
admission   normal  <  quarantine
```

`required` preserves a source whether or not the plan reached it; `auto`
preserves it if the build plan used it; `ignore` does not preserve it — and a
real `ignore` is grantable by the trusted base policy and by nothing else.

A source-local annotation joins **upward** on each axis independently. An
annotation asking for something weaker leaves the base value standing and is
recorded as `POLICY_CONFLICT`.

Precedence is **selector weight**, never file order:

```
contentIdentity 40   aliasPath 30   repo 12   owner 8   originHost 6   kind 2
```

Highest specificity wins each axis independently. A tie assigning **different**
values on one axis **fails closed** — not last-wins, which makes the verdict a
function of file order, and not most-restrictive-wins, which is a silent join
hiding a policy nobody wrote. A unit test reverses the whole policy file and
asserts that not one verdict moves.

A fact recorded `UNKNOWN` does not match a selector — not permissively, not
conservatively — and the non-match is recorded with the rule id and the
selector name, so an inert rule is diagnosable instead of mysterious.

## Four digests, not one

Hashing the whole discovery document answers every question with "something
changed", which is the same as answering none of them. So:

| | what it covers |
|---|---|
| `dependencyContentDigest` | identity of the required dependency **bytes** — never `drvPath`, never `lockNodeId` |
| `policyFactsDigest` | exactly what a selector can read, **including provenance** |
| `flakeSourceDigest` | the project's own source, separately |
| `effectiveDecisionDigest` | decisions, matched rules and the trusted policy revision |

The useful results are the **disagreements**:

```
origin moved, bytes identical   content SAME    facts CHANGED   -> ORIGIN_MOVED
a README edit                   content SAME    facts SAME
                                flakeSource CHANGED             -> PROJECT_SOURCE_ONLY
a source annotated              nothing moves                   -> NO_RELEVANT_CHANGE
```

A README edit is a README edit. It is never reported as a change to 166
external dependencies.

## The adversarial corpus

Five proposals with a base state and a head state, in
[`fixtures/`](fixtures/) — **generated from a seed**, not written by hand:

```sh
./bin/nse-pg corpus --seed <a facts document> --corpus-dir <where>
```

That is not a convenience. A hand-written facts document is the "fixture the
world never produces" shape, and the pre-registration makes the corpus mean two
different things depending on where its seed came from:

| `SEED_PROVENANCE` | what a passing corpus means |
|---|---|
| `SYNTHETIC` | a **mechanism test**, indexed as one, **not** evidence for C1/C2/C3 |
| `RECORDED` | the graph came off a real Nix; the corpus is evidence |

So the corpus is a *function* of a seed, and the identical mutations run against
both. The checked-in fixtures use the synthetic seed so the corpus runs with no
Nix and no network; CI regenerates it from a recorded facts document and gates
that too. `fixtures/SEED.json` records which one a tree was built from, and a
unit test asserts the checked-in copy is byte-for-byte the generator's output.

The base policy is **derived from the seed** as well — one rule per origin host
the seed contains, one `contentIdentity` rule per source whose origin was never
observed, and a default of `quarantine`. A fixed policy written against a
3-dependency seed quarantines half of a real 150-dependency graph, every control
goes red, and the corpus stops proving anything.

The adversarial dependency each mutation *adds* is constructed in every case. A
recorded seed makes the **graph** real; it does not make the **attack** real,
and this line does not claim it does.

**Every fixture is gated base-against-base first**, and
that control must be `ACCEPTED`: a corpus whose baseline is already red proves
nothing about any mutation. The first version of this corpus had exactly that
defect — all five rejected, three of them for a reason unrelated to what they
were built to show.

| fixture | rejected by |
|---|---|
| `policy-self-exemption` | `QUARANTINED_DEPENDENCY` (+ cochange) — and the report shows what the candidate's own policy *would* have allowed |
| `judge-replacement` | `JUDGE_MISMATCH`, exactly and only |
| `workflow-replacement` | `WORKFLOW_MISMATCH`, exactly and only |
| `origin-moved` | `QUARANTINED_DEPENDENCY`, exactly and only |
| `policy-dependency-cochange` | `POLICY_DEPENDENCY_COCHANGE`, exactly and only |

Four of the five reject on **one** finding, asserted as an exact array. If a
guard were deleted, its specimen would go green.

## Running it

```sh
# the whole corpus, with its controls -- no Nix, no network, no store
./tests/pg-unit.sh

# one proposal
./bin/nse-pg gate --trusted-root  experiments/policy-governed/fixtures/origin-moved/base \
                  --candidate-root experiments/policy-governed/fixtures/origin-moved/head \
                  --out /tmp/gate.json
./bin/nse-pg summary --gate-report /tmp/gate.json

# with a Nix: a facts document from a real graph, then a verdict
./bin/nse-pg facts   --installable 'path:'"$PWD"'/fixture#default' --out /tmp/facts.json
./bin/nse-pg decide  --facts /tmp/facts.json --policy nix-source-escrow.toml \
                     --policy-rev "$(git rev-parse HEAD)"
```

Everything the authority boundary rests on runs without Nix. That is a design
constraint, not a convenience: a gate that can only be re-tested with a store
and a network is a gate nobody re-tests.

## The untrusted phase

```
local.   ephemeral.   credential-free.   candidate untrusted.
```

Enforced, not intended. The preflight refuses a non-`file` scheme, refuses a
local path outside the scratch directory, refuses a guarantee it cannot name,
and scrubs credential-shaped variables from the environment **before** anything
of the untrusted phase starts — then checks the environment that phase will
actually see. Nothing is built and no store is written to when it refuses.

**No byte produced by the untrusted candidate phase reaches durable storage in
this version.** There is no durable storage for it to reach.

## Cache

A shared cache may hold content-addressed **bytes**, which anyone can
re-verify against a hash. It may not hold **conclusions** about them, which can
only be believed.

A candidate that plants its own `gate-report.json` saying `ACCEPTED` gets it
found, named in the report, and not read — and the proof is not that sentence,
it is that the decisions come out byte-identical to the same run without the
planted file.

## What is proven, and what is not

The separation of trusted root from candidate root is proved **locally**, as
semantics, by the corpus above.

> **NO CLAIM:** that a workflow inside a personal GitHub repository provides
> real GitHub-level judge independence. It does not. The workflow in this
> repository is a **measurement instrument**, not a gate — it lives in the head
> of the branch it measures, which is exactly the weakness fixture C is about.
> Real enforcement needs an organization-level required workflow or an external
> trusted judge, and that is a separate envelope and a separate deployment
> decision.

> **NO CLAIM:** that authenticated durable promotion is solved. It is not
> attempted. Storage topology here is local, ephemeral and credential-free.

Also out of scope by construction, and listed so nobody has to infer it:
authenticated S3, Attic, Software Heritage, remote durable promotion,
credentials, GitHub secrets, selective egress, `pull_request_target`, a GitHub
App, an organization transfer, a production required workflow,
`FULL_AIRGAP_REBUILD`, compatibility with an older nixpkgs, and importing
PR-built artifacts into a durable escrow. If any of them turns out to be
*required*, work stops and it is recorded as a new envelope — `PREREG.md` §20.

## Acceptance: where each item stands

`PREREG.md` §21 lists what this line must establish before it can be called
done. Each item, and where it was established — the run numbers are in
[`runs.json`](runs.json), which is the only place a run is indexed.

| item | where |
|---|---|
| **C1** candidate cannot weaken governing policy | fixture A: the exemption the candidate wrote is shown to be real and shown not to apply |
| **C2** candidate cannot replace governing judge | fixture B, plus the same gate run over this repository's own tool files |
| **C3** same content + changed origin re-evaluates | fixture D: content digest unchanged, facts and decision digests both moved |
| **C4** annotation moves `.drv`, not outputs, no rebuild | run 2, both Nix versions, verdict `C4_AS_PREREGISTERED` |
| `owner`/`repo`/`rev` measured on both Nix versions | run 1 — all three `DERIVATION_ATTR`, and the two versions agreed while emitting different document schemas |
| bare `escrow=true` classified explicitly | run 1 — `DIRECT_ATTR_REJECTED` on both versions |
| typed digests have red controls | both halves for each: the mutation that must move it and the one that must not |
| decisions carry matched-rule provenance and policy revision | asserted per decision; measured on a real 150-source graph in run 3 |
| head policy is preview only | fixture A, and the preview is in the report so a reviewer can see what it *would* have done |
| head judge is not authority | fixture B; the report records `candidateJudgeExecuted: false` |
| acceptance store remains fresh | CACH3, observed rather than assumed |
| cache is accelerator only | all five. CACH1/CACH4 in run 3 (34.5s → 17.2s, every semantic field identical); CACH2 in run 5; CACH3 observed rather than assumed; CACH5 demonstrated by planting a verdict the gate then ignores |
| every new guard has a falsifying specimen | one branch of the scratch-prepare guard has no portable specimen and says so rather than faking one |
| the closed line's tests remain green | 186/186, on a byte-identical `tests/unit-shell.sh` |

### CACH2, and why it took two runs

Run 4's step produced a green it was not capable of earning. It corrupted a
zlib **build output** — which under `SOURCE_ORIGIN_INDEPENDENCE` is not in the
population the escrow covers at all — and then read the resulting `PASS` as the
control holding, when a `PASS` cannot distinguish *Nix rejected the corrupted
bytes* from *the corrupted bytes were escrowed and replayed*. That green was
withdrawn and recorded as `INCONCLUSIVE` rather than kept.

Run 5 measured it properly. The victim is taken from the escrow's own discovery
document, so it is certainly a source the escrow holds; the verdict is decided
by copying the object back out of the escrow and comparing hashes, with
`VIOLATED`, `HELD_*` and `NOT_MEASURED_*` as distinct outcomes:

```
victim:          /nix/store/43b4f9gi…-source
corrupted file:  hello-2.12.1/configure.ac
sha256:          24814d9d…  ->  88006ecf…
run:             exit 1, SOURCE_ORIGIN_INDEPENDENCE FAIL
CACH2:           HELD_RUN_REFUSED
```

The corrupted bytes did not reach the escrow. The difference between the two
runs is the specimen: one was outside the population and one was inside it.

## Inherited, not re-derived

The discovery, preserve, verify and prove stages belong to the closed line and
are **invoked, not rewritten** — the way a second study reuses a calibrated
instrument from the first. Its conclusions are not inherited with it. Its unit
suite must keep passing untouched, and it does; it has caught three defects in
this line's code so far, including two `local` declarations that would have
reintroduced an `E2BIG` crash it had already paid for once.

The rules both lines work under are in
[`EXPERIMENT-PROTOCOL.md`](../../EXPERIMENT-PROTOCOL.md).
