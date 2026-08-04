---
slug: model-consensus-is-not-independent-evidence
origin: BootIt
session: bootit-2026-08-04-hardware-run
date: 2026-08-04
target: spine
relevance: all — any project running a multi-model triangulation gate (C-TRIMODEL) and recording its output as a basis for design decisions
status: pending
reliability-target: L2
hook: A prediction that survives three independent models can still be false, and only measurement settles it. BootIt's tri-model gate had two of three legs predict that `proc_pid_rusage` counts buffer-cache writes and would race to payload size in ~2 minutes then freeze; the first instrumented run showed it tracking the device counter to within 1.2% across 29 minutes. The decision that prediction supported was still right, for a different reason — but "two of three models agreed" had been recorded as evidence when it was consensus, and consensus among models trained on overlapping data is not independent confirmation.
---

## The lesson

BootIt's copy-progress design ran the federation's C-TRIMODEL gate. On sub-question D2 —
does the per-process byte counter measure what reaches the device, or what reaches the
kernel's cache? — two of the three legs said cache, and predicted the observable signature:
it would sprint to the payload size within about two minutes and then freeze, reproducing
the `df` failure one layer up.

That prediction went into the synthesis, into the code comments, and into a fixture
docstring, phrased as the thing an instrumented run would *confirm*.

The run happened. Across 28.8 minutes the process counter tracked the device counter the
whole way and finished **1.2% below** it. No sprint, no freeze. On that hardware it would
have worked perfectly well as a numerator.

**The decision it supported did not change**, and that is the important half. The reason the
app shows no percentage is that the *denominator* is unknowable before the run:
`createinstallmedia` does not announce how much it intends to write, and the amount that
lands is not the amount the device writes. A second well-behaved numerator supplies no
denominator. The load-bearing argument held; a supporting one did not.

## Why this class of thing survives

Three models agreeing feels like triangulation and reads like replication. It is neither.
They are trained on overlapping corpora, so a plausible-and-widespread belief about how a
platform API behaves is exactly the kind of thing they will agree on *and* be wrong about
together. The agreement measures how common the belief is, not how true it is.

It is worse when the prediction is *specific and falsifiable* — "races to payload in two
minutes, then flatlines". Specificity reads as expertise. Here the specificity was the most
useful thing about it, but only because someone eventually went and looked.

The failure mode is not running the gate. The gate was right to run and its output was
right to record. The failure mode is **recording a converged prediction with the same
confidence as a measurement**, so a later session reads it as settled and never checks.

## How to apply

- In a tri-model synthesis, mark every claim as **prediction** or **measurement**. A
  converged prediction is a strong prior and a research task; it is not a finding.
- When a decision rests on several arguments, name which one is **load-bearing**. BootIt's
  survived its supporting argument being falsified precisely because "no denominator exists"
  had been written down separately from "the process counter is untrustworthy".
- Record the falsifying observable *at gate time* — "if this is right, column X flatlines by
  minute 2" — so the check is cheap and obvious later. BootIt did this, which is the only
  reason one run settled it.
- When measurement contradicts the consensus, **do not reflexively change the design**. Check
  whether the load-bearing argument still holds. Changing a shipped decision because a
  supporting argument fell over is how a fourth wrong answer ships.
- Say plainly in the record that the models were wrong. The temptation is to quietly restate
  the conclusion, since the conclusion survived; that leaves the next reader trusting a
  prediction that has already failed once.
