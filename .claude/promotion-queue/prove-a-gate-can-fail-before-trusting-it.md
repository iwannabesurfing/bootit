---
slug: prove-a-gate-can-fail-before-trusting-it
origin: BootIt
session: bootit-2026-08-04-hardware-run
date: 2026-08-04
target: spine
relevance: all — any repo adding a CI step, a lint rule, a sanitizer, a smoke test or any other automated check
status: pending
reliability-target: L3
hook: A CI gate must be proven to FAIL before it is trusted to pass. BootIt added `swift test --sanitize=thread` and verified both directions first — restoring a known race to confirm exit 1 with 8 warnings, then the fixed tree to confirm exit 0 — because the same repo had already shipped a release workflow whose signing steps silently skipped and reported success. A step that cannot go red is worse than no step: it converts an unchecked property into one everybody believes is checked.
---

## The lesson

BootIt had shipped three threading bugs in one subsystem. The third was found only because
someone ran a sanitizer by hand; nothing obliged them to. The fix was to put
`swift test --sanitize=thread` in CI.

Before trusting it, both directions were checked against the real runner behaviour:

- **Mutated tree** — restore the unsynchronised `AppModel.ingest` → `swift test --sanitize=thread`
  exits **1** with **8** ThreadSanitizer warnings naming the exact functions.
- **Fixed tree** — exits **0**, zero warnings, three runs running.

Only then was the step added, deliberately *not* `continue-on-error`.

This mattered because the assumption underneath was not obvious: ThreadSanitizer does not halt
on the first error by default, and whether a data-race warning translates into a non-zero process
exit is a property of the sanitizer runtime, not of the test framework. "The tests still pass, so
it printed warnings and moved on" was an entirely plausible outcome, and would have produced a
permanently green step that checked nothing.

## Why this class of thing survives

The repo had already been bitten by precisely this shape. Its release workflow gated the signing
and publishing steps on secrets that did not exist; absent secrets resolved to empty strings, the
`if:` conditions evaluated false, the steps were **skipped**, and the job reported **success**. A
release "published by CI" had in fact been notarised locally and uploaded by hand. Nobody noticed,
because the only signal — green — was the signal you get when everything works.

A green check is read as evidence. Nothing in a passing pipeline distinguishes "this property
holds" from "this step is incapable of noticing". The two are indistinguishable *forever*, because
the check that would tell them apart is the failing case nobody arranges.

## How to apply

- **Every new automated check gets one deliberate failure** before it is believed: break the thing
  it guards, confirm red, restore, confirm green. Record both results in the commit message.
- **Never add a check as advisory** (`continue-on-error`, warning-only, non-blocking) as a way of
  easing it in. That is the silent-success shape by construction.
- **Be suspicious of exit codes you have not observed**, especially from sanitizers, linters in
  non-strict modes, and any tool whose diagnostics go to stdout. Printing a problem and failing
  are different behaviours.
- **Treat skipped as failed** when a step is conditional on configuration. A conditional step whose
  condition silently evaluates false is the most convincing green there is.
- Re-run the falsification after any refactor that moves the code the check anchors on — the earlier
  result certified a shape that no longer exists.
