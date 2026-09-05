# Experiment protocol

Rules for building checks that are capable of disagreeing with you.

This started as the internal hygiene of one Nix source-escrow experiment. It is
in its own file because it turned out to be the part that transfers: the escrow
result is about Nix, this is about how not to build a test that can only agree
with its author. Nothing below is a principle someone reasoned out in advance.
Each line is the scar of a specific measurement that went green while measuring
nothing, and the count is not flattering — **five defects in the implementation,
six in the instruments that were supposed to catch them, and one sampling
design that refuted a correct hypothesis.**

`DESIGN.md` §15, §15a, §16, §16a and §17–§18 in that repository are the case
histories. This file is the rules without the archaeology.

The reason it is worth reading rather than nodding at: in that series the rules
were **prospectively validated**. They did not merely explain six instruments
that had already failed — they rejected the seventh before its output could
become a conclusion. A protocol that has only ever been applied backwards is a
narrative device.

---

## 1. The qualification rule

> **Before relying on a check, state the observable trace that would make it
> report failure. If you cannot describe one, or the construction of the check
> cannot produce one, it is not a check.**

It is a green lamp wired directly to the battery.

Apply it to tests, probes, assertions, dashboards, monitors and acceptance
criteria alike. Two minutes, out loud, before the thing is trusted:

* What exactly would be red here?
* Can this construction *emit* that state at all?
* Has it ever actually been red? If not, make it red once, deliberately.

Every measurement defect in the source series failed this at the first
question.

And one more question, added after a check that answered correctly and took
seventeen minutes to do it:

> **What does a red one cost?**

A refusal nobody can afford to wait for is a refusal that will be worked around,
disabled, or mistaken for a hang. Timing is part of the contract: measure how
long the failing path takes, not only that it fails. In the source series a
fail-closed store probe was exactly right and interrogated 227 objects one at a
time, each with its own network retry, before reporting that the store was down.

### The shapes it catches

| shape | what it looks like | the case |
|---|---|---|
| **asserts a constant** | reads a field that is always the same value on the tested path | an exit code initialised to `0` for a command that only ran under a non-default flag: `0 == 0`, forever |
| **destroys its own specimen** | the check aborts the run before any verdict exists | `find … \| head` under `pipefail` + `set -e` ended the suite mid-way |
| **contaminates what it measures** | the probe's own invocation determines the answer | a schema probe run without `-r` saw one derivation and reported "no fixed-output derivations" about a graph with 165 |
| **passes only while the code is fail-open** | it goes red the moment the code starts failing closed | an assertion that survived only because a parser ignored a non-zero exit |
| **fixture the world never produces** | the input shape under test does not occur in reality | both fixtures used a key form the real tool emits in neither of its two schemas |
| **non-representative sample** | the sample cannot exhibit the difference being investigated | printing the first two items refuted a *correct* hypothesis, because both happened to be the uninteresting kind |

The last one deserves its own warning. A bad sample does not merely fail to
confirm — **it disconfirms with exactly the same confidence**. Three runs of
counting anomalies settled nothing; one run that *named* them settled it in the
first line. Count to detect, name to diagnose.

---

## 2. Unreadable is not empty

> `MISSING` / `UNPARSEABLE` / `UNKNOWN_SCHEMA` **is not** `EMPTY`.
>
> Where something is guaranteed non-empty: *expected non-empty **and** observed
> zero* → **FAIL or UNVERIFIED, never PASS**.

`0 of 0 = 100%` is an extremely effective way to produce green reports. A parser
that cannot tell it from a real result is not a parser, it is a rubber stamp.

Corollaries paid for in this series:

* An unrecognised response shape is a **fatal error**, not an empty answer.
* A structural key is not a semantic fact. `{"path": null}` has the key and does
  not have the path.
* An absent field read through a default operator becomes a plausible statement
  about the world. jq's `//` treats `false` as absent, which turned a
  conclusion of "no" into a printed "unknown" — three separate times, in a
  repository whose own docs warn about that operator.
* A field with exactly one possible value is decoration, not evidence. Delete
  it or make it able to vary.

---

## 2a. A failed observation must never become a decision

The strong form, worth stating separately because the weak form is easy to
agree with and still get wrong:

> No negative claim may be derived from an incomplete observation, and no
> verdict may be derived from an invalid measurement.

Two distinct failure modes hide behind one bug:

```
UNKNOWN -> ABSENT                  a measurement failure becomes a fact
UNKNOWN -> ABSENT -> MAY_PROCEED   a measurement failure becomes a POLICY
                                   DECISION
```

The second is materially worse and much easier to ship, because the code path
reads like ordinary error handling. In the source series a probe that failed
was read as "the store says it does not have it", which then authorised a
rebuild of the object. A wrong number is a wrong number; a wrong number that
steers an action is an incident.

The permitted shape is `UNKNOWN -> STOP`. Where an observation has three
outcomes — holds it, does not hold it, did not answer — exactly one of them may
change state, and it is not the third.

Corollary for any conversion or defaulting: `UNKNOWN -> <concrete value>` is the
same defect wearing different clothes. "Algorithm not recorded, assume sha256"
is "store did not answer, assume absent" with better manners.

---

## 3. Presence is not necessity

> Observing that X is present while the system works shows **presence**. It does
> not show X is **required**.

Necessity needs an ablation: remove X, and require a pre-defined red trace.
Until someone runs that, write the boring sentence:

> *The tested run succeeds while only these remain present.*

Not "these are the ones it needs". The verb is the whole claim.

---

## 4. Pre-register the intervention

Before a change whose point is to establish something, write down:

1. the exact observables that must be **unchanged**, with their current values;
2. the outcomes that count as **red**, each classified in advance with what
   happens next;
3. the one or two observables that have **no legitimate route** to move, and the
   explicit note that a move means *the change did something*, not that a new
   value needs explaining.

The third item is the one that pays. Naming a content hash in advance and
recording "if this moves, investigate, do not narrate" removes the temptation
that arrives with a surprising number at 2am.

**And check the criterion is satisfiable by the change it pre-registers.** One
in this series was not: it required experiment outcomes to stay green after
deleting the mechanism those experiments toggled. An experiment cannot outlive
its own manipulandum. That was caught before the intervention; had it been
caught after, the honest fix and the convenient fix would have looked identical.

If the criterion has to be amended, amend it **before** the judging run, in
writing, with the reasoning visible — and amend only what is about the
instrument, never an observable of the system under test.

---

## 5. A measurement cannot be both the reason and the test

The runs that justify a change are its **justification**. They cannot also be
its **acceptance test**. Freeze their final values as the reason, then judge the
change by observables that survive it.

When an instrument is retired with its subject, retire it explicitly and record
its last values. A harness that silently stops measuring is worse than one that
is deleted, because the report looks the same.

---

## 6. Keep the identities apart

At minimum, and machine-readably:

```
measured_commit        the tree the run actually executed
evidence_recorded_by   the commit that wrote the result down -- necessarily
                       later, and NOT itself measured
reference_commit       the frozen subject, if there is one
```

Collapsing these into "current HEAD" is how a measurement gets attached to a
state nobody ran. A result whose provenance is a rumour is a rumour.

Corollary: stamp provenance at **build** time, not by asking the environment at
run time. An installed artefact has no working tree to interrogate.

---

## 6a. A run is not automatically an experiment

Pushing a documentation commit triggers the same CI as a code change. That
execution is **operational verification** — it confirms the tree still builds.
It is not a new empirical claim, and it should not be indexed as an
experimental run.

Without the distinction the run index becomes a graveyard of identical green
executions in which the numbers grow and the knowledge does not. Index a run
when it carries a claim; record the rest, if at all, as what they are.

---

## 7. Removal is a stronger experiment than repetition

A disabled mechanism and an absent one are different claims. Toggling a flag
off shows the system tolerates the flag being off; deleting the mechanism shows
the behaviour never depended on it. Only the second is a causal check.

Deletion also buys falsifiability, not just tidiness: it removes a region of
state space where a regression could exist unexamined. After the removal, the
default path *is* the validated configuration, with no bypass switch — so a
future regression turns the ordinary suite red instead of being quietly worked
around.

And when a line of work is closed, closing it is the correct move. Another
identical green run costs time and yields almost no information. **The next run
should exist because a new falsifiable claim exists** — not because green is
pleasant to look at.

---

## 7a. A test whose subject is an absence needs a presence control

The hardest check to keep honest is one that asserts something is *not* there —
a secret absent from an artifact, a host unreachable, a phrase missing from a
file. It passes when the property holds. It also passes when the run died before
the subject ever appeared.

> A value that was correctly redacted and a value that never arrived look
> **identical** from outside.

So the absence assertion is never the whole test. Something alongside it must
establish that the subject was in play: a positive control that goes red when
the run does not reach the code path under test. And when the redaction is doing
its job, that control cannot use the same observation — it needs its own run,
with a variant of the subject the system is guaranteed to echo.

The tell that this is missing: several assertions in the group pass when the
run does not happen at all.

---

## 7b. A fixture built from the system's own materials inherits its defaults

When a test builds its specimen out of artefacts the system under test produced,
the specimen arrives carrying whatever that system attaches by default —
signatures, permissions, cached metadata, provenance. Those defaults are not
neutral, and a specimen that carries one of them may satisfy the test for a
reason that has nothing to do with the property being measured.

So state what the fixture must **not** contain, and assert that too:

> A precondition that has never been observed to fail is not a precondition.

Remove the property rather than assuming its absence — strip the field, clear
the flag, start from empty — and assert the removal worked before the first
behavioural claim runs. "There probably aren't any" is not a measurement.

The tell: a negative leg passes, and the assertion that would explain why also
fails in the same run.

---

## 7c. A new object of study is a new envelope, not one more test

When the remaining work introduces something the finished work never contained —
a network, a credential, a third party, a kernel facility — it is not a leftover
of the current experiment. It is a new envelope, and it needs its own question,
its own pre-registration, and its own red traces described in advance.

The test for this is mechanical: **list what the new thing drags in with it.**
If the list contains items the existing evidence has never had to attribute a
failure to, the envelope has changed.

Attaching a new object of study to a closed envelope is how instrumentation
disasters begin, because the existing checks were designed for a world that did
not contain it. They will go green anyway — and a green check that was never
designed to see the new failure mode is worse than no check, since somebody will
cite it.

Closing an envelope is therefore a real deliverable, and it is stated as one:

> Within <the envelope investigated>, the evidentiary contour is qualified and
> closed. The outstanding work belongs to new envelopes: <name them>.

The next piece of work then starts at a question, not at the next run number.

---

## 8. Scope the conclusion to what was run

Name the envelope in the sentence that states the result: this fixture, these
versions, this platform, this configuration. Two CI jobs do not license a
universal claim about a tool, and unqualified conclusions from small envelopes
are not in short supply.

---

## Checklist

Before trusting a check:

- [ ] I can describe the trace that makes it red.
- [ ] Its construction can actually emit that trace.
- [ ] It has been red at least once, deliberately.
- [ ] It fails on an unreadable answer instead of treating it as empty.
- [ ] It does not read a field that has one possible value.
- [ ] Its fixture is a shape the real system emits.
- [ ] Its sample can exhibit the difference under investigation.
- [ ] I have measured how long its FAILING path takes, not only its passing one.
- [ ] I have EXECUTED it, not merely parsed it. A syntax check is not an
      execution check: a call that lost its arguments is still valid shell.
- [ ] Its subject was actually present to be measured. If the check asserts an
      ABSENCE, something separate establishes that the thing existed to be
      absent from.
- [ ] Its fixture does not carry a default of the surrounding system that would
      satisfy the check on its own. What it must NOT contain is asserted, not
      assumed.
- [ ] It is inside the envelope that was actually investigated. Anything that
      introduces a new object of study gets its own envelope, not an extra
      assertion in this one.
- [ ] Its own success case cannot abort the run. A tool that signals "found
      nothing" with a non-zero exit will end an errexit script from inside the
      assertion that was about to pass.
- [ ] I ran the project's OWN checker with the project's OWN flags, not a
      similar command with a status I then interpreted.

Before an intervention:

- [ ] Observables that must not move are written down with current values.
- [ ] Red outcomes are classified in advance.
- [ ] The criterion is satisfiable by the change it judges.
- [ ] The justifying measurements are frozen, and are not also the test.

Before writing the result down:

- [ ] The verb matches what was measured (presence vs necessity).
- [ ] The envelope is in the sentence.
- [ ] `measured_commit` is not the same thing as the commit recording it.
