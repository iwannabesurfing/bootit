---
slug: the-bug-is-in-the-untested-seam
origin: BootIt
session: bootit-2026-08-04-copy-progress
date: 2026-08-04
target: spine
relevance: all — any codebase with a well-tested pure core reached through glue, which is most of them
status: pending
reliability-target: L2
hook: When a heavily-tested pure core is fed by an untested seam, the bug is in the seam. BootIt's copy reducer had 14 tests and a replay harness; the glue delivering samples to it had none — and that glue mutated the reducer from the XPC delivery thread and the worker queue at once. The review brief pointed at the scariest-looking code (an IOKit registry walk, which was flawless) and the defect was in the plain-Swift plumbing nobody had thought to look at.
---

## The lesson

A subsystem was rebuilt so its logic would be a **pure function** of a recorded sample stream —
specifically so it could be falsified in milliseconds instead of by a 40-minute hardware run. That
worked: the reducer got 14 tests, six mutation checks, and a fixture that reproduces the original
defect.

Then an independent review found a data race — not in the reducer, in the four lines that fed it:

```swift
func ingest(_ sample: CopySample) {
    let state = copyModel.ingest(sample)   // runs on whichever thread delivered the callback
    onMain { self.copyState = state }      // only the DERIVED state is hopped to main
}
```

`copyModel` (a struct holding an `Array`) was also reset from a different queue when the run ended.
Two writers, no synchronisation. ThreadSanitizer reported the race and killed the test process with
signal 5.

**Three things made this seam invisible:**

1. **The core's test coverage read as the subsystem's test coverage.** 14 tests, all green, all
   exercising `CopyProgressModel` directly — none of them going through `ingest`.
2. **The seam looks trivial.** Two statements. Nothing in it invites scrutiny, and it is the kind of
   code that gets written last, after the interesting part is done and reviewed.
3. **Attention was pointed elsewhere.** The review brief named an IOKit registry walk with manual
   retain/release as the top concern. That code was correct in every path. The reviewer's own note:
   *"the actual concurrency defect is one level removed from where IOKit ownership lives — in the
   pure-Swift glue, which is easy to miss because the reducer itself is exhaustively tested while the
   seam feeding it has no test coverage at all."*

## Why the usual instinct fails here

Purity is a property of the core, not of the path into it. Making something a pure function does not
make its *call site* safe — and the whole reason for the refactor (this thing is expensive to test)
guarantees the call site stays the least-tested part, because the call site is the part that still
needs real I/O to exercise.

The refactor arguably *creates* the risk. Before it, the logic and the plumbing were one lump nobody
could test. After it, the logic is exhaustively tested and the plumbing is exactly as untested as it
was — but now surrounded by green.

## How to apply

- When reviewing (or briefing a reviewer on) a diff with a well-tested pure core, **say explicitly
  that the seam is where to look.** Coverage counts describe the core; they say nothing about the
  glue, and they actively mislead about it.
- Ask "what thread is this on?" at every callback boundary — SDK callbacks (XPC, URLSession, IOKit
  notifications, socket reads) arrive on queues you did not choose and are not documented at the
  call site.
- **Where a codebase already locks shared state, an unlocked one is the finding.** BootIt's daemon
  locks its progress fraction and its work registry; the trace writer owns a serial queue. The one
  unsynchronised mutable field was the anomaly, and grepping for the *absence* of the local pattern
  would have found it faster than reasoning about threads.
- Run the sanitizer. This was a two-second `swift test --sanitize=thread`, and it converted "a
  reviewer's argument" into "an observation with a stack trace" — which is what made it safe to act
  on immediately rather than debate.

## Receipt

BootIt `06e184e` (introduced) → `db3d349` (fixed), 2026-08-04. TSAN reported
`data race CopyProgressModel.swift:160 in CopyProgressModel.ingest(_:)`,
`data race CopyProgressModel.swift:197 in CopyProgressModel.track(_:)` and
`Swift access race AppModel.swift in AppModel.ingest(_:)`; the test process exited with signal 5.
Mutation-checked: restoring the off-main ordering reproduces 8 TSAN warnings. The exposure window is
the tail of every run — `DispatchSourceTimer.cancel()` does not interrupt a handler already running,
and the daemon stops sampling only after sending the reply that unblocks the app.
