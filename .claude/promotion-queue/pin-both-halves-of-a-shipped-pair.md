---
slug: pin-both-halves-of-a-shipped-pair
origin: BootIt
session: bootit-2026-08-03-release
date: 2026-08-03
target: spine
relevance: all — any project shipping a client and a server (daemon, helper, sidecar, worker) inside one artefact
status: pending
reliability-target: L4
gate: fdd-field
hook: When a fix spans a client and a server that ship inside ONE bundle, a verification run proves nothing unless both sides are pinned to the same build — and that has to be measured, not assumed. BootIt spent an hour diagnosing a "failure" that was a 10:36 app talking to a 10:56 helper across a changed XPC method signature; the mismatch was invisible until the app's process start time was compared against the bundle's mtime.
---

## The lesson

A change moved every failure reply across an XPC boundary from a string prefix to an `NSError`
code. It touched both halves of a pair — the GUI app and its privileged daemon — that ship as one
`.app` bundle and are always built together.

The verification run reported failure. It looked like the change was broken.

It was not. The user had an app open since **10:36**. The bundle on disk had been rebuilt at
**10:56**, after the commit that changed the protocol. macOS keeps the running binary alive through
its open file handle, so the process in memory still spoke the old protocol while launchd started
the daemon from the *new* bundle on disk. XPC compared the two method signatures, found `NSString`
where the other side declared `NSError`, and dropped the connection.

Three independent measurements settled it: the commit time (10:56), the bundle mtime (10:56), and
`ps` start time for the running app (10:36:13). The unified log named the collision outright — a
method-signature dump with `class 'NSString'` on one side and `argument 1: type encoding (@)
'@"NSError"'` on the other, followed by `XPC_ERROR_CONNECTION_INTERRUPTED`.

## Why it fails silently

Nothing in the system is wrong from its own point of view. The app is a valid build. The daemon is
a valid build. Both are correctly signed and pass each other's code-signing requirements. The only
defect is that they are different *ages*, and no single component can see that.

Worse, the project's existing staleness check actively reported **healthy**. It detects a stale
daemon by fingerprinting the helper binary on disk and comparing it to the running daemon's — and
both were new. The one stale party was the process doing the asking, which is exactly the party a
self-check cannot see.

The failure then presents as a bug in whatever was most recently changed, which is the most
expensive possible misdirection: it sends you to re-read correct code.

## How to apply

- **Before any verification run on a client/server pair, prove both halves are the same build.**
  Cheapest reliable check: compare the running process's start time against the artefact's mtime.
  If the process is older, it is not testing what you think.
- Quit and relaunch as part of the install step, not as an afterthought. "Rebuild and reinstall"
  is incomplete if a stale process survives it.
- When a protocol changes shape (signatures, serialisation, enum wire format), treat a connection
  error as a **version-skew hypothesis first** and a logic bug second. Check ages before code.
- Consider making skew self-announcing: have each side report a build fingerprint on connect and
  fail with "these are different builds" rather than a generic transport error. A staleness check
  that only looks outward cannot catch the case where the caller is the stale one.
