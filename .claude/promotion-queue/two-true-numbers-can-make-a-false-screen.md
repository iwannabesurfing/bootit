---
slug: two-true-numbers-can-make-a-false-screen
origin: BootIt
session: bootit-2026-08-05-cancel-and-v3.4.1
date: 2026-08-05
target: spine
relevance: all — any UI showing a live measurement beside a state label, especially during transitions
status: pending
reliability-target: L4
gate: test:mac/Tests/BootItTests/CopyPresentationTests.swift
hook: "Cancelling — waiting for the drive to respond" above a byte counter reading 1.00 → 1.145 GB and rising. Both accurate: the signal genuinely had not landed, and the drive genuinely was still writing. The screen still lied, because a user resolves a contradiction between a label and a number by trusting the number — and concludes the label is wrong.
---

## The lesson

Correctness of each element is not correctness of the composition. A status line and a live counter
are two claims presented as one statement, and the user reads the statement.

When they disagree, the number wins. It is concrete, it is moving, and it looks like evidence —
whereas a label looks like something the app decided. So "waiting to stop" beside "still going up"
is read as *the stop didn't work*, which was the exact wrong conclusion in BootIt's case: the cancel
had landed correctly and the write stopped seconds later.

## What to do about it

**Suppress the true value rather than caveat it.** This is uncomfortable and it is right. The
alternatives are worse:

- *Caveat it* ("1.145 GB written — this will stop shortly") — now the screen is arguing with itself
  in the user's peripheral vision, at the moment they are least inclined to read carefully.
- *Freeze it* — a frozen counter is indistinguishable from a hung app, which is the failure mode
  this whole subsystem exists to avoid.
- *Show it anyway* — the observed outcome, and the reason this lesson exists.

Removing it is the only option that leaves one claim on screen. Do it narrowly: BootIt suppresses
the liveness line **only** while a cancel is pending, and it is the single place in the app that
deliberately hides a measured number — worth stating at the call site so it is not later "fixed".

## The general test

For each pair of things on screen, ask: **if these two disagree, which does the user believe, and
what will they conclude?** If the answer to the second is wrong, they must not be shown together.
Transitions are where this bites, because states are usually designed as steady pictures and the
in-between is drawn by whatever the previous state left behind.

## Applies when

Progress UIs, sync indicators, connection status beside throughput, "saving…" beside a live word
count, any cancel or pause over work with latency. Pairs with
[[an-undeliverable-cancel-needs-a-state]], the case that produced it, and with
[[an-unestablished-reading-is-not-a-negative-one]] — both are about which direction a display should
fail in when it cannot be fully honest.
