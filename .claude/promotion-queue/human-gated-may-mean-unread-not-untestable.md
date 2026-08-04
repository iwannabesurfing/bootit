---
slug: human-gated-may-mean-unread-not-untestable
origin: BootIt
session: bootit-2026-08-05-admin-gate-and-previews
date: 2026-08-05
target: spine
relevance: all — any backlog carrying items labelled "needs a device / a second account / a human to look"
status: pending
reliability-target: L4
gate: fdd-field
hook: An item filed as human-gated stops being re-examined — the label reads as a verdict on the question rather than a note on one proposed method. Two items sat open four sessions here as "5 min on a test account" and "needs Xcode open". One was answered by a header already on disk; the other needed a human, but only for 30 seconds and only after the plan built on it had been falsified for free.
---

## The lesson

"Human-gated" is a claim about **a method**, not about a question. Once written down it is
read as the latter, and the item stops being thought about: it is not blocked on anyone's
decision, so nobody revisits it, and it does not appear in any list of blockers.

Two items had survived four sessions in BootIt this way.

**One did not need a human at all.** "Test whether `SMAppService` registration is
admin-gated — 5 min on a test account." The rule was stated in `SMAppService.h`, in the SDK
already installed on the machine, and the derived reading was pinnable by tests against
accounts every macOS install ships. The estimate was honest; the framing was not — nobody
had asked whether the experiment was the only route to the answer.

**One did need a human, and the label still cost more than it saved.** "Does Xcode render
`#Preview` for a SwiftPM executable target?" It genuinely needs a canvas and an eye. But the
*plan* attached to it — restructure into a library target — rested on a premise that could
be falsified for free with a five-line probe. It was false. The item's real cost was never
the 30 seconds of human attention; it was carrying an unverified plan for four sessions.

## The check that would have caught both

Before writing "human-gated" next to an item, answer two questions:

1. **Is there a primary source?** A header, a spec, a regulation, a changelog. Documentation
   the vendor wrote about their own behaviour outranks an experiment you would run to infer
   it — and is usually already on disk.
2. **What does the human step actually decide?** Often the human is needed for a *verdict*
   while the *premise underneath the plan* is machine-checkable. Falsify the premise first.
   A cheap probe that kills a plan is worth more than a human confirming a symptom.

And when the human step survives both, **scope it to seconds**: name the exact file, the
exact setting, the exact click. The reason these items rot is not that people refuse them —
it is that "open Xcode and investigate" has no defined end.

## Applies when

Any backlog item deferred for a device, an account, a credential or a pair of eyes.
Re-read the label as "the method I first thought of needs a human" and ask the two questions
before carrying it forward one more session.
