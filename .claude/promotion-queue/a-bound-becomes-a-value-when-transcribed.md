---
slug: a-bound-becomes-a-value-when-transcribed
origin: BootIt
session: bootit-2026-08-05-copy-progress-correction
date: 2026-08-05
target: spine
relevance: all — any design note, review comment or research synthesis whose conclusion is expressed as a limit ("cap at", "clamp to", "never exceed", "at most", "no more than N")
status: pending
reliability-target: L4
gate: test:mac/Tests/BootItTests/RecordedRunTests.swift
hook: A guardrail written as a CEILING gets implemented as a VALUE. BootIt's tri-model synthesis recorded "clamp to 95%" — never exceed 95% before the process exits. The code returned exactly 0.95, on the one phase the same document said must show no number at all. "Never more than N" and "N" are one careless reading apart, and the reading happens months after the document is written.
---

## The lesson

A synthesis, review or FDD says: *clamp to 95%* · *cap retries at 5* · *no more than 200 ms* ·
*at most 3 concurrent*. Every one of those is a **bound on a computed value**. None of them is the
value. The transcription error is to make it the value, and it is easy because the bound is the only
number in the sentence.

BootIt's case is the clean form. UNANIMOUS #7 of its synthesis reads "never reach 100% before the
process exits successfully", with Gemini's formulation recorded as "clamp to 95%". §3.2 of the *same
document* requires the phase in question to show an "indeterminate activity ring — animated, not a
frozen number". Those are consistent: **if** a determinate bar exists, it may not exceed 0.95; on
this phase, no bar exists.

What shipped:

```swift
if line.contains("Making disk bootable") { return 0.95 }
```

A constant, on the indeterminate phase, from a ceiling meant for the determinate one. It then held
95% for **25.6 minutes of a 30-minute run**, which is exactly the pathology the clamp existed to
prevent — reached by implementing the clamp.

## Why it survives review

The number is *right there in the source document*, so a reviewer checking "does the code match the
synthesis?" finds 0.95 in both and stops. Matching a literal is not matching a claim. The question
that catches it is: **"is this number a bound or an output?"** — and if a bound, "what computes the
value it bounds?" If the answer is "nothing", the bound has been mistaken for the value.

Compounding it: a bound has no natural test. `XCTAssertLessThanOrEqual(x, 0.95)` passes trivially
for a constant 0.95, so the obvious assertion certifies the defect.

## How to apply

- **Name bounds as bounds in code.** `maxRingBeforeExit` reads wrong when returned directly;
  `0.95` does not. The name is the review surface.
- **Assert against the bound's purpose, not its value.** Not "is it ≤ 0.95" but "does the bar reach
  0.95 only near the end" — which needs a real trace, and is how BootIt's was eventually caught.
- **When transcribing a document into code, quote the sentence, not the number.** BootIt's comment
  said "emitted right at the end", an invented justification; the synthesis never said that.
- If a bound survives into a branch where the bounded computation does not exist, that branch is
  where the bug is.

## Applies when

Any design document, tri-model synthesis, security review or performance budget becomes code.
Especially where a gate was run to *produce* the number, because the gate's authority transfers to
the literal and stops anyone asking what it was a bound on. Pairs with
[[a-stage-banner-marks-a-beginning]], the signal this particular constant was hung from, and
[[a-filtered-state-may-be-the-one-that-violates]], the test exemption that let it live.
