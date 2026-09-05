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
[`fixtures/`](fixtures/). **Every one is gated base-against-base first**, and
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

## Inherited, not re-derived

The discovery, preserve, verify and prove stages belong to the closed line and
are **invoked, not rewritten** — the way a second study reuses a calibrated
instrument from the first. Its conclusions are not inherited with it. Its unit
suite must keep passing untouched, and it does; it has caught three defects in
this line's code so far, including two `local` declarations that would have
reintroduced an `E2BIG` crash it had already paid for once.

The rules both lines work under are in
[`EXPERIMENT-PROTOCOL.md`](../../EXPERIMENT-PROTOCOL.md).
