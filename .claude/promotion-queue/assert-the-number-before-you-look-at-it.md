---
slug: assert-the-number-before-you-look-at-it
origin: BootIt
session: bootit-2026-08-04-hardware-run
date: 2026-08-04
target: spine
relevance: all — any session that writes prose describing measured behaviour, or turns a recorded dataset into tests
status: pending
reliability-target: L4
gate: fdd-field
hook: A test written from assumption fails in seconds where the same assumption in prose survives for months. Turning BootIt's first recorded run into assertions immediately refuted two beliefs the agent had already stated confidently in a report — that filesystem used-bytes goes *blind* mid-run (it goes static; only 16 of 865 samples were nil) and that it stays frozen to the end (it ticks once at unmount). Both had been written as observations after glancing at two samples.
---

## The lesson

BootIt captured its first fully instrumented run: 865 samples over 28.8 minutes. Early in the
run the agent looked at the first dozen samples and reported two things to the user as
observations:

1. "`processBytes` is flat at 0."
2. "`volumeUsedBytes` vanishes after sample 3 — the control column failing exactly as documented."

Both were wrong. `processBytes` was zero only because bulk copying had not started; it climbed
for the rest of the run. `volumeUsedBytes` was nil for **16 samples out of 865**, all in the
first 38 seconds, and was present for the other 849 — where it did something far more
interesting than vanishing: it reached 99.9% of its final value at 18% of the way through the
run and then sat motionless for over fifteen minutes.

The second belief then got written into a test — `XCTAssertGreaterThan(blind.count, 100)` — and
**failed on the first run**, reporting 16. The corrected assertion is stronger than the original
claim and is now the sharpest evidence in the project for why three previous implementations
failed.

A third assumption failed the same way minutes later: "it stays frozen to the end" was refuted
by a single sample at unmount.

## Why this class of thing survives

Prose has no test runner. A confident sentence about measured behaviour reads exactly like a
measurement, and the reader cannot tell that the author looked at twelve samples out of 865.
The same sentence inside `XCTAssert` is checked in milliseconds.

The pull is strongest during a long-running job, when partial data is arriving and there is an
audience: an early read *feels* like progress reporting. It is actually the same
extrapolate-from-a-glance error that the instrumentation was built to eliminate, committed by
the person building the instrumentation.

## How to apply

- **Write the assertion before looking at the answer.** State the number you expect, run it,
  and let the failure tell you. This inverts the usual order — fit the claim to the data — which
  produces assertions that can only pass.
- **Label partial reads as partial, every time**, with the sample count and what would change
  the conclusion: "88 s into a 15–45 min run; the predicted flatline could still arrive."
- **Turn any dataset worth describing into tests**, not bullet points. If a claim about the data
  matters enough to report, it is cheap enough to assert.
- **When a test written alongside a claim fails, suspect the claim first.** Both failures here
  were the assertion being wrong about reality, not reality being surprising.
- Correct the earlier statement explicitly rather than quietly shipping the right assertion. The
  wrong sentence has already been read.
