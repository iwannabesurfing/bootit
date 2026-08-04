---
slug: deleting-the-caller-is-not-deleting-the-dead-code
origin: BootIt
session: bootit-2026-08-04-copy-progress
date: 2026-08-04
target: spine
relevance: all — any language whose compiler does not flag unused declarations, which is most of them for public/protocol surface
status: pending
reliability-target: L4
gate: fdd-field
hook: Deleting a caller is not deleting the dead code. BootIt removed `currentHelperVersion()` as one-occurrence dead code in the same commit that left standing the XPC method it called — under a freshly written comment asserting a fallback capability nothing implemented. A comment describing an intention is indistinguishable from a comment describing behaviour, and it converts dead code into dead code with an alibi.
---

## The lesson

A commit deleted a private method that had exactly one occurrence in the codebase: its own
definition. The commit message made a point of it — *"deleted rather than left unused, both being
one-occurrence dead code of the kind this repo has now been bitten by twice."*

The method it deleted was the only caller of an XPC protocol method. That method stayed, and got a
new comment:

> `helperVersion` stays on the XPC protocol: it costs nothing, and it is the one thing that can
> still be asked of a daemon too old to know what a fingerprint is.

**Nothing implemented that fallback.** There was no branch anywhere that called `helperVersion` when
the fingerprint check failed. The comment described something the author found plausible while
writing it, and a reviewer correctly identified it as a third instance of the exact defect the same
commit claimed to be eliminating.

## Why this is worse than plain dead code

Plain dead code gets found. Someone greps, sees one occurrence, deletes it.

Dead code with a stated rationale **survives that grep**. The next person finds two occurrences — a
declaration and an implementation — plus a comment explaining why it must stay. Everything looks
intentional. The comment is now load-bearing evidence for a claim that was never true, and the
strongest signal (one occurrence, no callers) has been destroyed by adding the second occurrence.

The mechanism is ordinary: deleting a caller feels like the finish of a cleanup, so attention drops
right at the moment the *callee* becomes dead. And writing a justifying comment feels like diligence
rather than like asserting an untested claim.

## How to apply

- **After deleting a caller, grep what it called.** Deletion propagates upward; a cleanup that stops
  at the first symbol has usually just created the next one.
- **A comment claiming a capability is a claim about code that must exist.** "This is kept as a
  fallback for X" is only true if something branches to it when X happens. If nothing does, the
  honest comment is that it is unused — and the honest action is to delete it.
- **Count occurrences, not references-in-prose.** The tell is `definition + implementation +
  zero call sites`. In Swift this is invisible to the compiler for anything `public` or on a
  protocol; the same holds for exported symbols in TypeScript, Python and Go.
- **Prefer wiring the fallback to describing it.** If the fallback is genuinely worth having, it is
  usually a handful of lines — and then the comment is true.

## Receipt

BootIt `06e184e` (2026-08-04) deleted `currentHelperVersion()` and retained `helperVersion` on
`HelperProtocol` with the comment above; `db3d349` deleted both halves after
`senior-swift-review` flagged it: *"Either wire the fallback the comment describes, or delete it per
the repo's own stated standard from this same commit message."* On inspection the fallback bought
nothing real either — a daemon that cannot answer `helperFingerprint` fails the call, and a failed
call already triggers re-registration.

A second instance in the same session, caught by grep rather than by review: `pruneOldTraces` was
written, unit-tested, and never called — one occurrence, its own definition — which would have let
trace files accumulate without bound. Written and tested is not wired.
