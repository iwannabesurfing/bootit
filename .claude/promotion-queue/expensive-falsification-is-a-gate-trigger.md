---
slug: expensive-falsification-is-a-gate-trigger
origin: BootIt
session: bootit-2026-08-03-release
date: 2026-08-03
target: spine
relevance: all — any project with a design gate that fires on "hard to reverse", and any decision whose test loop is slow or human-gated
status: pending
reliability-target: L4
gate: fdd-field
hook: A design gate that only ever fires when the user demands it has already failed. BootIt's progress indicator passed all three C-TRIMODEL tests and the agent queued a fourth patch instead of flagging it. The missed tell: "hard to reverse" should be read as **how expensive is falsification**, because a decision that cannot be cheaply tested will ship wrong repeatedly — this one shipped wrong three times.
---

## The lesson

A progress indicator was fixed three times across three sessions. Each fix addressed the mechanism
that had just failed:

1. read the first percentage in a line → reported 0% forever;
2. parse the tool's output → the long phase emits no percentages;
3. poll filesystem used-bytes → measures *allocation*, so it hit 95% in four minutes and froze for
   the remaining 33 of a 38-minute operation.

After finding the third failure, the agent queued a fourth fix of the same kind ("use device I/O
counters") — in the same session in which it had written, in a promotion file, that *"when the same
user-visible symptom returns after a fix, suspect the source of truth, not the reader."*

The user objected that there had been no real investigation and asked for a triangulation. Three
independent models then rejected the **framing** rather than the implementation, unanimously: the
error was never in the reader.

## Why the gate did not fire

The gate's three tests were all satisfied, and the agent evaluated none of them:

- **Foundational** — this surface is the entire UI for 38 of 40 minutes of the app's primary operation.
- **Hard to reverse** — this is the one that was misread. The agent assessed it as "a contained
  component, cheap to change", which is true of the *code* and irrelevant. What matters is that
  **falsifying the design costs a 40-minute human-gated hardware run**. That is why three wrong
  answers each survived to ship: nobody could afford to test them.
- **Genuinely open** — five materially different approaches existed (device counters, per-process
  counters, syscall tracing, calibrated time estimation, or abandoning the percentage entirely), and
  the models split on the central question.

## The generalisable correction

**Read "hard to reverse" as "expensive to falsify", not only "expensive to rework."**

A decision whose test loop is slow, manual, human-gated, or requires physical hardware will ship
wrong repeatedly, because each wrong answer survives long enough to look settled. Cheap-to-change
code with an expensive test loop is *more* dangerous than expensive-to-change code with a fast one —
the low rework cost is exactly what licenses another unvalidated guess.

Corollary, and the highest-value output of the eventual triangulation: **when falsification is
expensive, the first deliverable is not the fix — it is making falsification cheap.** All three
models independently proposed the same thing: record traces from real runs, commit them as fixtures,
make the logic a pure function of the trace, and replay offline. That converts a 40-minute hardware
test into a sub-second unit test, and it should have preceded attempt #2.

## How to apply

- When weighing a gate's "hard to reverse" test, ask **"how would I find out this was wrong, and
  what does that cost?"** If the answer is a slow or human-gated loop, treat it as hard to reverse
  regardless of how small the diff is.
- A recurring user-visible symptom that has survived two fixes is itself a gate trigger. Stop
  improving the mechanism; write down what the surface is required to *say*, then test that.
- Where falsification is expensive, budget the first unit of work to making it cheap — recorded
  traces, replay harnesses, throttled fakes. Include a **mutation check** that replays a real
  failure trace through the *old* implementation and asserts it reproduces the known pathology, so
  the fixture proves the fix rather than merely accompanying it.
- Note that capturing a lesson is not applying it: the promotion file naming this exact
  anti-pattern was written in the same session the anti-pattern was repeated. Check a fresh lesson
  against the **next** decision, not against the write-up. See [[report-what-you-were-told-not-what-you-inferred]]
  and [[progress-from-used-bytes-measures-allocation]].
