---
slug: deleting-the-mechanism-leaves-the-belief
origin: BootIt
session: bootit-2026-08-05-copy-progress-correction
date: 2026-08-05
target: spine
relevance: all — any fix that removes a component blamed for a defect, especially a well-documented removal made after a review or design gate
status: pending
reliability-target: L4
gate: test:mac/Tests/BootItTests/RecordedRunTests.swift
hook: BootIt deleted a used-bytes denominator because it froze the bar at 95% early, wrote a thorough comment explaining why, and left a hand-written `return 0.95` firing on the same event, one file away. The mechanism was removed; the belief that produced it was not. The symptom returned unchanged, and the removal's own comment made it look handled.
---

## The lesson

A defect has a mechanism and a belief. Deleting the mechanism is visible, satisfying and reviewable.
The belief is what wrote it, and it usually wrote more than one thing.

BootIt, 2026-08-04: `copyFraction(used:expected:)` divided filesystem used-bytes by an estimated
payload and "reached 95% in four minutes of a 38-minute write and never moved again, because JHFS+
allocates the extents up front". It was deleted — carefully, with the estimate machinery beside it,
and a comment explaining the whole thing.

2026-08-05, on a real run, the bar reached 95% in four minutes of a 30-minute write and never moved
again.

The surviving cause was `return 0.95` on a stage banner in a different file. **Both fired at the
same instant**: JHFS+ allocates every extent at the moment the tool prints `Making disk bootable`,
so the used-bytes reading and the banner are two instruments observing one event, at 13% of the run.
One was condemned in a committed test; the other shipped in the UI; nobody put them side by side.

## Why the good fix made it worse

The deletion comment was excellent, and that was the problem. It named the pathology precisely
enough that anyone later seeing a bar frozen at 95% would read it and conclude the case was known
and handled. A thorough post-mortem on a *partial* fix is stronger evidence of completeness than a
partial fix deserves — cf. [[a-subsystem-where-every-piece-exists-reads-as-finished]].

## How to apply

- **State the belief, not just the mechanism, in the removal.** "Used-bytes is not a progress
  source" is a mechanism. "Nothing that fires when the filesystem allocates may be read as progress"
  is the belief — and it visibly covers the banner too.
- **Grep for the event, not the code.** After deleting a reader of event E, search for every other
  consumer of E. BootIt's search term was the *timestamp* — one `grep` of a committed trace for what
  else happened at 309 s would have found it.
- **Reproduce the symptom, don't just remove the suspect.** The fix was verified by the deletion
  compiling and the suite staying green. The symptom was never re-run; it took a human watching a
  ring 24 hours later.
- Where the defect was "X reached 95% early", the regression test is *"nothing reaches 95% early"* —
  a property of the output, which survives any change of mechanism. BootIt now asserts this across
  every committed trace.

## Applies when

Any fix framed as "remove the thing that did it", and doubly so after a design gate, because the
gate's authority attaches to the removal and discourages asking what else it left behind. Pairs with
[[an-inference-recorded-as-observation-becomes-fact]] — the same repo, the same week, a claim written
into a comment while the refuting evidence sat committed beside it.
