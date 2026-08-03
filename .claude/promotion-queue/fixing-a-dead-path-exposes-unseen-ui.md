---
slug: fixing-a-dead-path-exposes-unseen-ui
origin: BootIt
session: bootit-2026-08-03-phase-0
date: 2026-08-03
target: spine
relevance: all — any session that repairs a code path which had never successfully executed
status: pending
reliability-target: L3
hook: Repairing a dead code path makes everything downstream of it reachable for the first time, and none of that has ever been reviewed — not by a user, not by a reviewer, often not by its author. Budget a look at the states the fix newly unlocks; they are the least-inspected code in the repo.
---

## The lesson

BootIt's Cancel button had never once worked. The moment it did, the screen behind it became
reachable — and it was blaming the user for pressing the button the app had offered:

- Title: **"Something went wrong"**
- Red error banner: `createinstallmedia failed: createinstallmedia exited 15`
- A "What to try" recovery hint
- A **Copy Diagnostics** button
- Phase checklist marking the stopped stage **"Failed"** with a red cross

Exit 15 is SIGTERM — the signal the app itself had just sent, on request. Every one of those
elements was correct code doing exactly what it said, reachable only via `runError != nil`,
which until that day only a genuine failure could produce.

Nobody had reviewed it because nobody had ever seen it.

## Why it is a distinct class

This is not "untested code". The path may be well covered by unit tests and still never have
been *looked at*, because tests assert values while this failure is about **meaning**: a
neutral outcome wearing the visual language of a fault. The states a dead path guards are
systematically the least-inspected in a codebase — they are, by construction, the ones no
session ever reached.

It also compounds: the longer a path stays dead, the more surrounding features accrete
assumptions that it never fires.

## How to apply

- When a fix makes a previously-impossible state possible, **enumerate what that state now
  reaches** — screens, log lines, buttons, analytics, notifications — and review each. Grep
  for the flag or error the path sets and read every branch that consumes it.
- Distinguish, in the model, **outcomes the user chose** from **faults**. One boolean is
  usually enough (`wasCancelled` beside `runError`) and it must reach the title, the banner
  style, the checklist state and the available actions — not just one of them.
- A user-initiated stop should never offer diagnostics to send: there is nothing to report,
  and asking implies they broke something.
- Say plainly in the close which newly-reachable states a human has actually looked at. The
  fix being unit-tested is not the same claim.
