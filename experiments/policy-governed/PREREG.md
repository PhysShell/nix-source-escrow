# Pre-registration — policy-governed source escrow under an untrusted change proposal

**Status: pre-registered. Written before the first experimental run of this line.**

This document is the contract. It is written first, and the implementation that
follows is judged against it — not the other way round. Where a run disagrees
with a line below, the line stays and the disagreement is recorded in
`runs.json`. Amendments are allowed; silent amendments are not. An amendment
made after the run it concerns is an amendment to the *next* run.

The rules this line inherits are in `EXPERIMENT-PROTOCOL.md` at the repository
root. §1 (the qualification rule) and §2 (unreadable is not empty) apply to
everything below without being restated at each point.

---

## 0. What line this is, and what line it is not

The previous line is **closed and frozen** at

```
84354e85872c385e649af0e1b90ef4a2e0997949
```

This line branches from that commit. It does not modify its history, its
`evidence-runs.json`, its `known-gaps.json`, or any of its recorded results.
`evidence-runs.json` is the index of the *closed* experiment and is not the
index of this one. This line's index is `experiments/policy-governed/runs.json`
and nothing else.

This is a new experiment. It reuses the previous line's discovery, preserve,
verify and prove machinery as *instruments*, in the same way a second study
reuses a calibrated instrument from the first. It does not inherit its
conclusions.

### Research question

> Can an escrow-governed Nix project derive preservation obligations
> automatically from the dependency graph of an **untrusted** candidate pull
> request, by applying a **trusted** declarative policy and a **trusted** judge,
> in such a way that the pull request cannot weaken the governing policy,
> replace the governing judge, or hide a policy-relevant change behind an
> unchanged content hash?

### The object of study

Not `escrow = true`. Not an annotation syntax. The object of study is:

> **Who is allowed to decide what must be preserved, when the proposed change
> itself is untrusted?**

The authority boundary is proved first. Credentials for durable storage are a
question for a later envelope, and are only worth asking once the boundary
holds.

---

## 1. Primary claims

Exactly four. Everything else in this document is mechanism, observable, or
supporting assertion, and is labelled as such. A supporting assertion that goes
red is a defect; it is not a refutation of a primary claim unless this document
says it is.

| id | claim |
|---|---|
| **C1** | A candidate cannot weaken its own governing policy. The policy that decides a candidate's verdict is read from the base revision; the candidate's copy is preview only. |
| **C2** | A candidate cannot replace its own governing judge. The judge implementation that produces a candidate's verdict is read from the trusted root; the candidate's copy is never executed as authority. |
| **C3** | A policy-relevant graph change cannot hide behind content equality. Two candidates whose required dependency bytes are byte-identical, but whose policy-visible facts differ, are distinguishable and are re-evaluated. |
| **C4** | A source policy annotation changes derivation identities but not realised output identities, and causes no rebuild work. |

### Refutation conditions, stated in advance

* **C1 is refuted** if a candidate-supplied `nix-source-escrow.toml` changes any
  effective policy axis of the verdict rendered on that same candidate.
* **C2 is refuted** if any byte of the candidate's judge implementation can
  affect the verdict, other than by being *reported* as changed.
* **C3 is refuted** if a candidate that moves a dependency's origin while
  keeping its content identity produces an identical `policyFactsDigest`, or is
  not re-evaluated against policy.
* **C4 is refuted** if annotating a source changes a realised output path, or
  causes any build step to execute that would not otherwise have executed.

---

## 2. Execution model, and the honest limit of this container

The machine this line is authored on **has no Nix** and **cannot reach
`github.com` over HTTP** (`403` through the egress proxy; `git` to this
repository's own origin is the only GitHub access that works). The pinned
fixture depends on `github:NixOS/nixpkgs`, so:

* Everything that needs a real Nix evaluation is **measured in CI**, on both Nix
  versions, exactly as the closed line did. Its results are recorded here and in
  `runs.json`.
* Everything that does not need Nix — the digests, the policy model, the
  matcher, the trusted-root/candidate-root gate, and the whole adversarial
  corpus — is **measured locally and in CI**, and is deliberately built so that
  it does not need Nix. That is not a convenience. The authority boundary is a
  property of the gate, not of Nix, and a gate that can only be tested with a
  network and a store is a gate nobody will re-test.

A CI workflow is added on this branch for measurement. **It is not claimed to be
a security boundary** — see §10.

---

## 3. Annotation experiment — observables registered before the run

### 3.1 Mechanism under test

Plain `overrideAttrs`, with **no wrapper**:

```
src.overrideAttrs (_: { nseEscrowCoverage = "required"; })
```

A wrapper is written **only if one of the assertions in §3.3 actually goes red**.
Writing one first would be designing around a failure that has not been
observed.

### 3.2 Pin

The pinned nixpkgs of the current fixture, and no other:

```
d2f67949798825fe853f7c5d0492b8bf016d3f88
```

Compatibility with older nixpkgs, where `fetchFromGitHub` was built differently,
is a **separate compatibility surface with a separate pin**, and is out of scope
for this line (§13, STOP condition).

### 3.3 Public attribute preservation — checked before any wrapper is considered

On the pin above, after `overrideAttrs`:

| attribute | expected |
|---|---|
| `src.owner` | SAME and readable |
| `src.repo` | SAME and readable |
| `src.rev` | SAME and readable |
| `src.tag` | SAME as before, or NULL as before |
| `src.meta` | semantically preserved |

A wrapper is justified by a red line in this table and by nothing else.

### 3.4 Derivation / output observables

Measured against a three-level chain — annotated FOD → direct consumer →
top-level — so that "direct consumer" and "top-level" are two different
derivations and not one derivation counted twice.

| observable | expected |
|---|---|
| source `.drv` | **DIFFERENT** |
| source output | **SAME** |
| direct consumer `.drv` | **DIFFERENT** |
| direct consumer output | **SAME** |
| top-level `.drv` | **DIFFERENT** |
| top-level output | **SAME** |
| `nix build` | **NO REBUILD WORK** |
| annotation visible to discovery | **YES** |
| `OBJECTS_REALISED` count | **SAME** |
| `OBJECTS_REALISED` set | **DIFFERENT** |
| `closureSha256` | **DIFFERENT** |

**Why.** A `.drv` is a text-content-addressed store object: its identity is the
hash of its own text, so adding an attribute to it necessarily changes its
store path. Nix's hash-modulo-fixed-output rule, however, resolves a
fixed-output input to the *content identity of its output*, not to the identity
of the `.drv` that produced it. So the change stops at the `.drv` layer and does
not propagate into any realised output.

`OBJECTS_REALISED` is `--requisites --include-outputs`, so the realised set
**contains the `.drv` files themselves** (this is the arithmetic of gap-23 in
the closed line, and it is why the count is expected to hold while the set
moves): three `.drv` identities change, three leave the set and three enter it,
and the cardinality is unmoved.

### 3.5 Registered in advance: `closureSha256` moving is NOT a regression

`closureSha256` is a hash over `closure.json`, which lists `.drv` paths. It is
**expected to change** here, and this is **pre-registered expected churn**. Any
later reading of that change as a regression is a misreading of this document.

### 3.6 What would make §3.4 a real refutation of C4

A changed *output* path, or any executed build step. Not a changed `.drv`. Not a
changed `closureSha256`.

---

## 4. Fact visibility — measured, not read off the nixpkgs source

On the pin above, `owner`, `repo`, `rev`, `tag`, `githubBase`, `stripRoot` and
`extension` are passed through derivation arguments. **The nixpkgs source is not
evidence for how either Nix serialises them.** The closed line has already been
burned by exactly this: the same tool, on the same flake, saw 165 fixed-output
sources on one Nix version and 0 on another, because the *document shape*
differed, not the graph.

So each fact is measured on:

```
Nix 2.24.9
Nix 2.34.7
```

Observables, per fact, per Nix version:

```
owner  repo  rev  tag  githubBase  stripRoot  extension
```

### 4.1 Provenance is mandatory and is part of the fact

Every fact carries how it was obtained:

```json
{ "owner": "NixOS", "ownerSource": "DERIVATION_ATTR" }
```

Permitted values of `<fact>Source`:

| value | meaning |
|---|---|
| `DERIVATION_ATTR` | read directly from a derivation attribute |
| `URL_FALLBACK` | parsed out of a URL, and **explicitly marked as such** |
| `UNKNOWN` | the attribute is absent and no permitted fallback applies |

**Amended 2026-09-05, before the run that measures it — see the Amendments log
at the end of this document.** A fourth value exists for flake inputs:

| value | meaning |
|---|---|
| `LOCK_ATTR` | read directly from a `flake.lock` `locked` record |

The three values above are the vocabulary for facts read out of a **derivation
document**, which is what §4 measures. A flake input's `owner`, `repo` and
`rev` are not in any derivation document; they are in the lock file, stated
there, and pinned by a `narHash`. Recording them as `UNKNOWN` would discard a
fact the project actually has; recording them as `DERIVATION_ATTR` would name a
document they did not come from. Both are worse than a fourth name.

Rules, registered in advance:

* An absent attribute yields `UNKNOWN`. It never yields a guess.
* **`rev` is never synthesised from a URL.** There is no `URL_FALLBACK` for
  `rev`; absence yields `UNKNOWN`.
* `URL_FALLBACK` is permitted for `originHost` only, and only when the direct
  attribute is absent, and only with the provenance recorded.
* Turning *attribute missing* into *guessed from URL* without recording the
  provenance is the same defect as defaulting a bare digest to sha256, and is
  forbidden by the same rule.

### 4.2 Supporting assertion, not a primary claim

Fact visibility is a **supporting assertion**. If a fact turns out to be
`UNKNOWN` on one Nix version, that is a recorded measurement about that version,
not a refutation of C1–C4. It does constrain which selectors the matcher may
rely on, and §7.3 says how.

---

## 5. Bare `escrow = true` — measured as an experiment, not shipped as an API

Measured separately:

```
pkgs.fetchFromGitHub { ...; escrow = true; }
```

Three outcomes are permitted in advance, and **each must have a distinguishable
trace**:

| outcome | trace requirement |
|---|---|
| `DIRECT_ATTR_REJECTED` | evaluation fails; the error text is recorded |
| `DIRECT_ATTR_DROPPED` | evaluation succeeds and the attribute is **absent** from the derivation document; the absence is asserted positively |
| `DIRECT_ATTR_SURVIVED` | evaluation succeeds and the attribute is **present** in the derivation document, at a named key |

**`DROPPED silently` cannot be scored as a success.** A mechanism whose failure
mode is indistinguishable from its success mode has not been measured. The
`DROPPED` branch is only reportable because the probe asserts the *absence*
positively — the probe must be capable of emitting `SURVIVED`, and this is
qualified by a red control that plants a known-surviving attribute.

Even on `DIRECT_ATTR_SURVIVED`, `escrow = true` is **not** promoted to a public
API by this line. Survival on one fetcher chain at one pin is a measurement of
that chain at that pin, not an interface.

The annotation mechanism of this line is, and remains:

```
src.overrideAttrs (_: { nseEscrowCoverage = "required"; })
```

or another explicitly `nse`-prefixed attribute.

---

## 6. Four layers, kept apart

Conflating any two of these is how a green report gets produced about nothing.
They are separate documents with separate schemas.

### FACTS — what discovery observed

```
content identity        (storePath, expectedHash, expectedHashAlgo, hashMode)
kind
requiredByPlan
originHost  owner  repo  rev  tag
aliasPaths
discoveryStatus
fact provenance
```

`EXTERNAL_RECOVERY` is a **discovery fact / status**. It is not a policy enum
and never becomes one.

### POLICY — what the project declared

Three independent axes, and no more in this line:

```
coverage    : ignore | auto | required
retention   : while-referenced | permanent
admission   : normal | quarantine
```

No Software Heritage. No recovery-backend behaviour. Those are other envelopes.

### DECISION — what the trusted judge concluded

Per source:

```
source identity
matched rule ids
trusted policy revision
effective coverage
effective retention
effective admission
mustPreserve
accepted | quarantined
```

### EVIDENCE — what actually happened

```
present
verified
scratch preserved
acceptance result
guarantee proved
```

The three sentences that this line is not allowed to violate:

> Policy is not evidence.
> A discovery fact is not policy.
> A decision is not an observation.

---

## 7. Annotations may only strengthen; policy is the authority

The trusted project policy is the authority. A source-local annotation is sugar.
It may raise an obligation; it may never lower one.

Each axis is a total order:

```
coverage  : ignore            < auto             < required
retention : while-referenced  < permanent
admission : normal            < quarantine
```

Effective value on each axis is the **join (max)** of the base policy value and
the annotation value.

| base | annotation | effective | recorded |
|---|---|---|---|
| `auto` | `required` | `required` | — |
| `required` | `ignore` | `required` | **`POLICY_CONFLICT`** |

A real exemption — a genuine `ignore` — is grantable **only by the trusted base
policy**, never by a candidate annotation.

### 7.3 Consequence of a fact being `UNKNOWN`

A rule whose selector reads a fact recorded as `UNKNOWN` **does not match**, and
the non-match is recorded with reason `SELECTOR_FACT_UNKNOWN`. It does not match
"permissively" and it does not match "conservatively" — it does not match, and
the source falls through to whatever less specific rule does. If nothing
matches, the policy default applies, and the policy default is a declared value,
not an implied one.

---

## 8. The policy that governs a proposal is the BASE policy

The policy file is `nix-source-escrow.toml`. A proposal may change it. That
changed file **does not govern the proposal that changes it**.

```
base policy  =  ENFORCED
head policy  =  PROPOSED / PREVIEW ONLY
```

Every decision document and every evidence document must record:

```
ENFORCED_POLICY_COMMIT=<base sha>
PROPOSED_POLICY_COMMIT=<head sha or NONE>
POLICY_CHANGED=YES|NO
```

When the TOML is changed, the check summary must say so **explicitly and in the
summary**, not only in a JSON artefact. A candidate policy must not be able to
release the candidate's own dependencies from base obligations.

---

## 9. CODEOWNERS is not a security boundary

`CODEOWNERS` may later be added as governance metadata. It is **not** used as
evidence of authority by this line, and no assertion here depends on it. On its
own it does not guarantee a required approval. Real GitHub authority depends on
branch protection, rulesets, or an external judge, and that is out of scope
(§13).

---

## 10. The judge does not come from HEAD either

This is the part that is easy to get wrong, so it is stated at length.

It is **not sufficient** for a head workflow to invoke `base/bin/...`, because
the candidate can change the workflow that does the invoking. The harness
therefore separates two roots and passes them to the gate as **different
inputs**:

```
TRUSTED ROOT                    UNTRUSTED CANDIDATE ROOT
  policy                          flake
  judge implementation            source
  policy schema                   candidate config
                                  candidate workflows
                                  candidate copy of the gate
```

The gate reads its policy, its schema and its own implementation from the
trusted root. It reads the graph, and only the graph, from the candidate root.
The candidate's copy of the judge is **hashed and reported**, never executed.

### What this line proves, and the sentence it is not allowed to say

This line proves the **semantics** of that separation, locally.

> **NO CLAIM:** that an ordinary workflow inside a personal GitHub repository
> already provides real GitHub-level judge independence. It does not, and this
> line does not argue that it does.

Real enforcement needs an organization-level required workflow, or an external
trusted judge / GitHub App. Both are a **separate envelope and a separate
deployment decision**, and neither is implemented here. The CI workflow added on
this branch is a **measurement instrument**, not a gate.

---

## 11. Adversarial proposal corpus

Five fixtures, minimum. Each is a **proposal with a base state and a head
state**, not a unit test of a function.

```
experiments/policy-governed/fixtures/
    policy-self-exemption/
    judge-replacement/
    workflow-replacement/
    origin-moved/
    policy-dependency-cochange/
```

### A. `policy-self-exemption` — C1

Candidate sets `coverage = "ignore"` for a source it is adding.

```
POLICY_CHANGED
ENFORCED_POLICY_REF=<base>
candidate policy does not govern the verdict
```

Required verdict: **REJECTED under the base policy.**

### B. `judge-replacement` — C2

Candidate replaces its own `bin/` judge with `echo PASS; exit 0`.

```
JUDGE_MISMATCH
TRUSTED_JUDGE_SHA=<expected>
```

Required verdict: **the malicious head judge is not used as authority, and the
proposal is REJECTED.** A judge change must land as a base change first, exactly
as a policy change must.

### C. `workflow-replacement`

Candidate edits the local workflow so the gate never runs, or is always green.

```
WORKFLOW_MISMATCH
TRUSTED_WORKFLOW_IDENTITY=<expected fixture identity>
```

Required verdict: **REJECTED.**

This fixture tests the **model and the harness**. It does **not** assert that a
personal GitHub repository already has an external required workflow — see §10.

### D. `origin-moved` — C3

Identical hash, identical content, different origin.

```
DEPENDENCY_CONTENT_UNCHANGED
POLICY_FACTS_CHANGED
ORIGIN_MOVED
```

Required: policy evaluation **re-runs**, and the re-run is observable —
`dependencyContentDigest` is unchanged, `policyFactsDigest` changes, and
`effectiveDecisionDigest` changes.

### E. `policy-dependency-cochange`

One proposal both weakens policy **and** adds a dependency that the weakening
would affect.

```
POLICY_DEPENDENCY_COCHANGE
→ FAIL
```

The first version is **deliberately conservative and refuses to be clever**. No
attempt is made to resolve such a merge. The policy change lands as a base
change first; the dependency arrives in a separate proposal afterwards.

### 11.1 Seed provenance — registered in advance

A hand-written facts document is a "fixture the world never produces"
(`EXPERIMENT-PROTOCOL.md` §1). So each fixture's facts are derived from a seed
by explicit, minimal, recorded mutation, and the seed carries its provenance:

| `SEED_PROVENANCE` | what a passing corpus means |
|---|---|
| `RECORDED` | seed is a facts document produced by the real discovery path on a real Nix. The corpus is evidence for C1/C2/C3. |
| `SYNTHETIC` | seed is hand-authored. The corpus is a **mechanism test only** and is indexed as such. It is not evidence for C1/C2/C3. |

A synthetic seed must nonetheless validate against the schema of a recorded
document, and the schema check is itself red-controlled.

---

## 12. Typed digests — four, not one

**The whole `discovery.json` is not hashed.** It carries volatile,
non-identity data, and a single digest over it answers every question with
"something changed", which is the same as answering none of them.

### `dependencyContentDigest`

Identity of the required dependency **bytes**, and nothing else.

* fixed-output sources: `storePath`, `expectedHash`, `expectedHashAlgo`,
  `hashMode`
* flake inputs: `storePath`, `narHash`
* canonical sort before hashing
* **not** `drvPath` — a policy annotation legitimately changes the `.drv`
* **not** `lockNodeId` — a lock node id is a name in a graph, not a content
  identity

### `policyFactsDigest`

Exactly the facts the matcher can see:

```
content identity  originHost  owner  repo  kind  aliasPaths  discoveryStatus
```

Registered consequence — this is the C3 observable:

```
origin changed, content identical
    dependencyContentDigest   SAME
    policyFactsDigest         DIFFERENT
```

### `flakeSourceDigest`

Identity of the project's own flake source, separately.

Registered consequence — a README-only change:

```
    dependencyContentDigest   SAME
    policyFactsDigest         SAME
    flakeSourceDigest         DIFFERENT
```

This is **normal**, and a README-only change must never be reported as a change
to 166 external dependencies.

### `effectiveDecisionDigest`

```
source identity  matched rule ids  effective policy axes  trusted policy revision
```

### 12.1 Red controls, registered in advance

Each digest has a mutation that must move it and a mutation that must not:

| digest | must MOVE on | must NOT move on |
|---|---|---|
| `dependencyContentDigest` | changed `expectedHash`, changed `storePath`, added/removed required source | changed `drvPath`, changed `originHost`, changed `lockNodeId`, reordered input |
| `policyFactsDigest` | changed `originHost`, changed `owner`, changed `discoveryStatus` | changed `drvPath`, reordered input |
| `flakeSourceDigest` | changed flake source identity | any dependency-only change |
| `effectiveDecisionDigest` | changed effective axis, changed matched rule set, changed trusted policy revision | reordered input |

A digest with no falsifying mutation is not a digest, it is a constant.

---

## 13. Matcher

Interface: `nix-source-escrow.toml` + the discovered graph. Nothing else.

Selectors supported in this line — a deliberately small set:

```
exact content hash / identity
originHost
owner
repo
kind
aliasPath
```

The DSL is not grown beyond this. Rule IDs are **mandatory**; a rule without an
id, or with a duplicated id, is a policy load error, not a warning.

### 13.1 Precedence — declared here, before the code exists

Precedence is **not** TOML order. Relying on TOML order accidentally is exactly
the kind of thing that works until someone sorts the file.

Each selector carries a fixed weight:

| selector | weight |
|---|---|
| `contentIdentity` | 40 |
| `aliasPath` | 30 |
| `repo` | 12 |
| `owner` | 8 |
| `originHost` | 6 |
| `kind` | 2 |

A rule's **specificity** is the sum of the weights of the selectors it actually
constrains. A rule that constrains nothing has specificity 0 and is the
default rule.

Resolution, **per axis, independently**:

1. Consider only rules that match the source and that constrain that axis.
2. The strictly highest specificity wins.
3. If two or more matching rules tie on specificity and assign **different**
   values on that axis: **`RULE_CONFLICT`, and the load fails closed.** Not
   "last wins". Not "most restrictive wins" — a silent join would hide a policy
   the author did not know they had written.
4. A tie assigning the **same** value is not a conflict.

Every decision records `matchedRules` — the ids of every rule that matched, and
for each axis the id of the rule that won it.

---

## 14. PR scratch — local, ephemeral, credential-free

```
candidate graph
  ↓ facts
  ↓ trusted base policy
  ↓ decisions
  ↓ local ephemeral scratch
  ↓ verify
  ↓ acceptance
```

No credentials. No durable storage. **No bytes produced by the untrusted PR
phase are promoted into durable escrow in this version.** Storage topology of
this line is `local`, `ephemeral`, `credential-free`, and the PR/candidate is
untrusted throughout.

---

## 15. Cache is an accelerator, never evidence

The existing staging store may be used as an accelerator. Two sentences bound
it:

> cache bytes ≠ evidence
> cached verdict ≠ evidence, and this one is worse

| id | rule |
|---|---|
| **CACH1** | A cache miss cannot change verdict semantics. |
| **CACH2** | Cache corruption cannot become evidence. |
| **CACH3** | The acceptance test store remains fresh / empty before selected objects are copied into it. |
| **CACH4** | The cache changes runtime cost and nothing else. |
| **CACH5** | Cached `VERIFIED` / `REQUIRED` / `PRESENT` decisions are never authoritative; the trusted judge recomputes them. |

A shared cache may hold CAS bytes. It may not hold authoritative conclusions
about them. The closed line's empty-acceptance-store invariant is preserved
unchanged.

---

## 16. The guarantee is part of the check name

The cost of the gate is part of the product. Cost is measured; proved semantics
are not traded for it.

The check name states the exact guarantee:

```
SOURCE_ORIGIN_INDEPENDENCE PASS
ESCROW_REPLAY PASS
```

Never:

```
Source escrow PASS
```

Governance and adversarial fixtures may use a cheaper guarantee **when it is
stated explicitly**. At least one control must show that the strong path
`ESCROW_REPLAY` remains compatible with the new policy machinery. The existing
default is not changed silently, or at all, by this line.

---

## 17. Red-control discipline

Every new guard has a specimen that makes it red. A guard trusted because it is
green on the happy path is a green lamp wired to the battery.

Specimens are required for, at minimum:

```
POLICY_CHANGED guard
JUDGE_MISMATCH guard
WORKFLOW_MISMATCH guard
ORIGIN_MOVED guard
digest consistency guard
annotation visibility guard
```

### 17.1 A checker error is its own failure state

`CHECKER_ERROR` is distinct from `PASS` and from `FAIL`.

Where a checker uses `jq` or shell substitution:

* stderr **must** be captured;
* non-empty stderr means **checker failure**;
* an errored checker may **never** degrade into an empty or negative result.

This is the closed line's §19 rule, carried forward because it was earned:
a `grep` that found nothing once killed a run, and a parser that could not read
a document once reported that the document was empty.

---

## 18. Order of work

Registered so that a later reordering is visible as a deviation.

| commit | content |
|---|---|
| 1 | **this document** + `runs.json`. No implementation. |
| 2 | facts qualification: direct `owner`/`repo`/`rev`/`tag` visibility, both Nix versions, provenance, bare `escrow=true` classification |
| 3 | annotation qualification: `overrideAttrs`, all §3 invariants, wrapper only on a real red |
| 4 | typed digests + unit tests + mutation/red controls |
| 5 | policy model + matcher: FACTS → POLICY → DECISION, rule provenance, monotonic annotations |
| 6 | trusted-root / candidate-root gate harness |
| 7 | adversarial corpus: five proposals, expected traces |
| 8 | scratch preservation + acceptance integration, reusing the existing stages |
| 9 | performance / caching controls, CACH1–CACH5, cold vs warm |
| 10 | docs + human-readable check summary |

No policy engine is written before commit 2 has answered what the facts
actually are.

---

## 19. Run and index discipline

This line has **its own** run index: `experiments/policy-governed/runs.json`.
Nothing is appended to the closed line's `evidence-runs.json`.

* A run is indexed **only if it measures a pre-registered claim.**
* Docs-only, cleanup and operational CI are **NOT AN EMPIRICAL RUN** and are not
  indexed.
* A GitHub Actions workflow number is not a number of knowledge, and is not
  used as one.

Each indexed run records:

```
commit
Nix version
fixture identity
primary claim(s)
expected trace
observed trace
verdict
artifact / provenance identity
```

---

## 20. STOP conditions

If any of the following turns out to be **required**, work stops and it is
recorded as a new envelope or gap. It is not routed around, and scope is not
extended to absorb it.

```
remote authenticated storage
credentials
pull_request_target
trusting an artifact of the PR phase
changing frozen experiment history
an old-nixpkgs compatibility pin
Software Heritage
selective network access
real GitHub judge independence being unprovable in the current
    personal-repo topology
```

These are not obstacles to be worked around. Each is the boundary of a different
envelope.

### Out of scope for this line, restated

```
authenticated S3          Attic                 Software Heritage
remote durable promotion  credentials           GitHub secrets
selective egress          pull_request_target   GitHub App
organization transfer     production required workflow
FULL_AIRGAP_REBUILD       old-nixpkgs compat
importing PR-built artifacts into durable escrow
```

---

## 21. Acceptance for this line

Not done until all of these hold:

- [ ] **C1** candidate cannot weaken governing policy — demonstrated by an adversarial proposal
- [ ] **C2** candidate cannot replace governing judge — demonstrated by an adversarial proposal
- [ ] **C3** same content + changed origin is observable and re-evaluates policy
- [ ] **C4** annotation changes `.drv` identities as pre-registered, changes no realised output, and rebuilds nothing
- [ ] `owner` / `repo` / `rev` facts measured on **both** Nix versions
- [ ] bare `escrow=true` behaviour classified explicitly into one of the three registered outcomes
- [ ] typed digests have red controls
- [ ] policy decisions carry matched-rule provenance and the trusted policy revision
- [ ] head policy is preview only
- [ ] head judge is not authority
- [ ] acceptance store remains fresh
- [ ] cache is accelerator only
- [ ] every new guard has a falsifying specimen
- [ ] the closed line's tests remain green

### And, separately

> **NO CLAIM:** real GitHub hosted-workflow authority is solved.
>
> **NO CLAIM:** authenticated durable promotion is solved.

Those belong to the next envelopes. Prove the authority boundary first. Only
after that does it make sense to give the decision credentials to durable
storage.

---

## 22. Amendments

Amendments are allowed. Silent amendments are not, and an amendment made after
the run it concerns is an amendment to the *next* run. Each entry says what
changed, when, and whether the run it affects had already happened.

### A1 — `LOCK_ATTR` added to the fact-provenance vocabulary (§4.1)

* **When:** 2026-09-05, during commit 4.
* **Affected runs:** none yet. Run 1 measured only derivation-document facts and
  used only the original three values; this amendment does not change anything
  run 1 recorded.
* **What:** a fourth provenance value, `LOCK_ATTR`, for facts read out of a
  `flake.lock` `locked` record.
* **Why:** §4 is about the derivation document, and its three values are that
  document's vocabulary. Flake inputs are not in any derivation document. Their
  `owner`, `repo` and `rev` are stated in the lock and pinned by a `narHash`.
  Calling them `UNKNOWN` would throw away a fact the project holds; calling them
  `DERIVATION_ATTR` would cite a document they did not come from.
* **What it does NOT change:** `URL_FALLBACK` remains permitted for `originHost`
  only. `rev` still has no fallback of any kind — `LOCK_ATTR` is a direct read,
  not an inference. `UNKNOWN` still means absent, and §7.3 still applies to it
  unchanged.
