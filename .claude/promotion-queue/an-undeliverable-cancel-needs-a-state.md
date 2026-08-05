---
slug: an-undeliverable-cancel-needs-a-state
origin: BootIt
session: bootit-2026-08-05-cancel-and-v3.4.1
date: 2026-08-05
target: spine
relevance: all — any UI cancelling work it does not itself control: a subprocess, a device write, a network call, a remote job
status: pending
reliability-target: L4
gate: test:mac/Tests/BootItTests/CopyPresentationTests.swift
hook: Cancel is not an event, it is a request with latency. A SIGTERM to a process in uninterruptible sleep is not delivered until it returns from the syscall — measured at twice in 85 seconds against a USB write — and through that window BootIt's screen still said "Copying macOS to the drive…" with the byte counter climbing. Every number was true. The only available reading was that the button did nothing.
---

## The lesson

Cancellation has three states, not two: **running**, **stopping**, **stopped**. Most code models two,
because the request and the effect are usually close enough together to look simultaneous. When the
work is owned by something else — a kernel in `D`/`U` state, a device, a remote worker — they are
not, and the gap is where the user decides your app is broken.

BootIt's cancel was *correct*. It stopped the write 85 seconds into a 30-minute job, orphaned
nothing, and reported the outcome honestly as cancelled rather than failed. What it lacked was any
representation of the interval, which was:

```
click ──▶ flag set, "Cancelling…" written to a COLLAPSED log
       │  status line: still "Copying macOS to the drive…"
       │  liveness:    1.00 GB → 1.145 GB, climbing
       ▼
      stop
```

## What to build

- **A window state distinct from the outcome state.** `isCancelling` (in flight) is not
  `wasCancelled` (how it ended). Collapsing them makes the terminal state unrenderable while the
  cancel is pending.
- **Name the wait, and name whose it is.** "Cancelling — waiting for the drive to respond" beats
  "Cancelling…", because it tells the user the delay is not the app being slow and not their click
  being dropped.
- **Disable the control.** A live Cancel through the window invites a second press whose only
  possible outcome is proving that pressing it does nothing.
- **Suppress progress counters that keep advancing.** See
  [[two-true-numbers-can-make-a-false-screen]] — this is the case that produced it.
- **Close the window on the single exit path that always runs**, not in the cancel's own completion
  handler. The work can finish *normally* in the seconds after the click, and then "waiting for the
  drive" is stranded on a run that succeeded.

## Applies when

Anything cancellable that you do not own the scheduler for: `Process`/`kill`, device I/O, `fetch`
with an AbortController against a server mid-write, a queued remote job. The tell is that you cannot
state a bound on the delay — if you cannot, the UI must represent the interval rather than assume it
away. Note this is invisible to tests by construction: a test cancels a fake that stops instantly,
so the window never opens. It took firing a real cancel at real hardware, once, four sessions after
it was first queued.
