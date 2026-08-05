---
slug: a-gates-decision-is-not-a-gates-implementation
origin: BootIt
session: bootit-2026-08-05-cancel-and-v3.4.1
date: 2026-08-05
target: spine
relevance: all — any process gate (tri-model, FDD review, design review, RFC) whose output is a document listing decisions
status: pending
reliability-target: L4
gate: fdd-field
hook: A gate's output is a document. A build is not a document, and nothing compares them. BootIt's tri-model synthesis listed nine UNANIMOUS decisions; #9 ("cancel must report the uninterruptible-sleep wait") shipped unimplemented for two sessions, and #2 and #7 were each implemented as the opposite of what they said — all while the synthesis sat in the repo being cited as the authority.
---

## The lesson

Running the gate is the visible, effortful, reviewable part. It produces a numbered list of decisions
and a strong feeling of closure. Then the list is *read once, during implementation*, and never
diffed against the result.

BootIt's synthesis, audited against the code eight weeks later — by accident, while fixing something
else:

| Decision | What shipped |
|---|---|
| #9 cancel must report the uninterruptible-sleep wait | **never built**; the only feedback was one line in a collapsed log |
| #7 "clamp to 95%" — a ceiling on a determinate bar | implemented as a **constant 0.95**, on the phase §3.2 said must show no number |
| #2 output parsing rejected because the tool "emits nothing" | the tool **does** emit percentages; the premise was false and a fixture in the repo proved it |

Three of nine, in a document that was cited as the reason the design was trustworthy. None of them
was caught by 241 passing tests, because the tests were written from the same reading of the
document as the code.

## Why the gate makes it likelier, not less likely

The gate's authority transfers to whatever was built next. "We ran a tri-model pass on this" ends
review conversations, so the artefact that most needs auditing is the one least likely to get it. A
decision nobody gated gets argued about; a decision three models agreed on gets implemented once,
badly, and defended by citation.

## How to apply

- **Turn each decision into a named, failing-first assertion at implementation time**, and put the
  decision's number in the test name or docstring. Then the document has a machine-checked index.
  Decisions that genuinely cannot be asserted (wording, layout) get listed explicitly as unverified —
  a short honest list beats an implied complete one.
- **Diff the document against the build, once, deliberately.** Read the numbered list against the
  code as a standalone task. It takes minutes and it is not the same as implementing from it.
- **Watch for the decisions with no obvious home.** #9 was about a transient UI state during a
  cancel — no file owns that, so it belonged to nobody and was built by nobody. Decisions that do
  not map onto an existing type are the ones that evaporate.
- **A decision whose premise came from observation needs the observation re-checked**, not just the
  conclusion re-read. #2's premise was falsifiable from a file already committed.

## Applies when

Any FDD, tri-model synthesis, ADR or design review that concludes with a list. Cousin of
[[a-bound-becomes-a-value-when-transcribed]] (how a decision gets mistranscribed) and
[[deleting-the-mechanism-leaves-the-belief]] (how a fix leaves its cause standing). All three are the
same shape: an artefact that records reasoning is treated as though it enforced it.
