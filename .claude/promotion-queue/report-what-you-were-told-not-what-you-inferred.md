---
slug: report-what-you-were-told-not-what-you-inferred
origin: BootIt
session: bootit-2026-08-03-release
date: 2026-08-03
target: profile:swift
relevance: swift — Apple-platform apps surfacing failures from a daemon, XPC peer, or any out-of-process component
status: pending
reliability-target: L3
gate: test:mac/Tests/BootItTests/EjectFailureTests.swift
hook: An app that decides what a failure MEANS instead of reporting what it was TOLD gives confident wrong guidance. BootIt asserted "USB access blocked" for a probe that never reached the helper, and discarded the daemon's own NSError message in two separate branches — sending the user to change a TCC setting that was never implicated. Three instances of one defect in a single session, each found by reading the screen against the code that produced it.
---

## The lesson

A privileged helper reports failures back across XPC as `NSError`s carrying a classification code
and a human-readable message. The app rendered them like this:

- **A test that never reached the helper was reported as "USB access blocked."** Nothing had been
  established in either direction — the connection failed — yet the screen named a cause, showed a
  warning icon, and offered Full Disk Access as the remedy. On the run that exposed it, the real
  cause was unrelated.
- **`helperError` was computed and thrown away.** The report struct carried the sentence explaining
  what went wrong; the summary that rendered it had a `default:` branch that ignored it. It would
  have read "the helper stopped unexpectedly" — which points straight at the actual cause.
- **`helperDenial` was computed and thrown away too.** The daemon carefully distinguishes a TCC
  denial (`needsFullDiskAccess`) from a read-only volume or an I/O error (`operationFailed` plus
  `strerror` text). Both rendered as the identical "add BootIt under Full Disk Access" — correct
  advice for exactly one of them.

The third one also weakened a verification run: because the daemon's message never reached the
screen, nothing distinguished *which* code had crossed the boundary, so the classification had to
be inferred from reading the daemon's source rather than observed from its output.

## Why it fails silently

Every one of these renders as a confident, well-formatted, plausible sentence. There is no crash,
no empty state, no `nil` — the UI looks *better* than a raw error would. The information loss is
invisible precisely because something helpful was substituted for it.

The pattern is a specific shape: a value is computed, stored on a model, and then not read by the
code that formats the output. Swift will not warn — the property is used elsewhere, the struct
compiles, the tests (if they assert on the summary at all) assert on the string that *is* produced.

It is the same family as two earlier defects in the same codebase: a `do/catch` around a
non-throwing ObjC method, where the catch body read as enforcement but could never execute; and a
failure classification smuggled in the first 24 characters of a human-readable sentence. In all
cases the app asserted something it had not established.

## How to apply

- **Distinguish "we observed X" from "we could not observe."** Any diagnostic needs a third
  outcome — ok / failed / **inconclusive** — and an unreachable dependency is inconclusive
  regardless of what the local half managed to do. Half a test is not a result.
- **Surface the message you were given, verbatim, alongside your interpretation.** The remedy you
  suggest is a guess; the peer's sentence is evidence. Print both.
- Grep for the shape directly: a property set on a result type and never read in the code that
  renders it. `helperError` and `helperDenial` were both live values with no reader.
- Assert the negative in tests: `XCTAssertFalse(summary.contains("blocked"))` for the inconclusive
  case catches a regression that no positive assertion will.
- When a message must be constructed from an optional, handle the empty-but-present case — a test
  here caught a sentence that trailed off after a colon before it shipped.
