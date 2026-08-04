---
slug: monitor-lifetime-is-human-latency
origin: BootIt
session: bootit-2026-08-03-phase-0
date: 2026-08-03
target: spine
relevance: all — any agent session that instruments a machine to capture evidence from a human-driven run
status: pending
reliability-target: L4
gate: fdd-field
hook: When an agent instruments for a verification a HUMAN will perform, the monitor's lifetime must be sized to human latency (hours), not agent latency (minutes). A one-hour process monitor expired three hours before the user started the run, and the timeline it existed to capture was lost — the failure is silent, because an expired monitor and an idle one look identical.
---

## The lesson

Before a hardware verification run, the agent started a 2-second-interval process monitor to
capture what the UI could not: whether a child process actually died on cancel, whether bytes
were still landing, whether a daemon exited when it should. Sensible instrumentation.

It was given a **one-hour deadline** — sized, without thinking, to how long the agent expected
to wait. The user started the run about three and a half hours later. By then the monitor had
exited, and the log held 1,727 samples of an idle machine.

The evidence for the single most important moment of the session — the first Cancel press —
was gone. It had to be reconstructed after the fact from a second run.

## Why it fails silently

An expired monitor produces a file full of blank samples. So does a monitor watching an idle
machine. There is no error, no gap, nothing that looks wrong — the agent reads the tail, sees
dashes, and reasonably concludes "nothing is running yet". The mistake surfaces only when the
interesting event has already passed unrecorded.

The underlying error is a **units mismatch in the mental model**: the agent's own loop is
measured in seconds-to-minutes, and it sized a human's loop with the same intuition. People
step away, take calls, and come back to a long-running task when convenient.

## How to apply

- Size any instrumentation that waits on a person in **hours**, and make expiry loud — write
  a terminating line to the log so an expired monitor is distinguishable from an idle one.
- Better: make it condition-terminated rather than clock-terminated — stop when the thing it
  watches has been seen and then finished, not when a timer runs out.
- Re-arm before handing over. If the instruction to the human is "do X now", confirm the
  instrumentation is live in the same breath, and re-check it when they report back.
- Record the *start* of the window in the log header, so a later reader can tell at a glance
  whether the run fell inside it.
