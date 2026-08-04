---
slug: cancel-on-the-queue-the-work-blocks
origin: BootIt
session: bootit-2026-08-03-phase-0
date: 2026-08-03
target: spine
relevance: all — any codebase with a long-running operation on a serial queue and a user-facing cancel
status: pending
reliability-target: L3
gate: test:mac/Tests/BootItTests/CancellationTests.swift
hook: A cancellation dispatched onto the same serial queue the work occupies can never run — it queues behind the operation it exists to stop. The UI's synchronous "Cancelling…" line still appears, so the button looks wired. Dispatch cancellation anywhere except the queue being cancelled.
---

## The lesson

BootIt's Cancel button shipped dead **twice**, for two different reasons, and the second was
caused by the fix for the first.

Round one: the XPC method, `ToolRunner.cancel()` and `PrivilegedHelper.cancel()` all existed,
and **nothing called the last one**. Every piece present is exactly why it read as finished.

Round two: the fix wired it up as

```swift
func cancel() {
    cancelFlag.cancel()
    log("Cancelling…")                                 // synchronous — user sees this
    worker.async { PrivilegedHelper.shared.cancel() }   // queued behind the write
}
```

`worker` is the **serial** queue the write pipeline occupies for its entire 10–20 minutes,
blocked inside an untimed semaphore wait. The cancel block could not start until the thing it
was meant to cancel had finished.

Measured, not inferred: Cancel pressed twice at 09:33; the tool wrote for **forty more
minutes** and exited normally at 10:14, never signalled.

## Why it survives review

The symptom is indistinguishable from a slow cancel, and the log line proves "something
happened". Reading `cancel()` in isolation, it is obviously correct — the bug lives in the
*relationship* between two functions in different parts of the file, one of which is the
queue declaration.

The tell is structural: **`worker` was serial, and the work and the cancel both used it.**
Note the asymmetry that should have been visible — the daemon serialised its work on a
`static` queue but kept its cancel handle per-instance, i.e. it had already reasoned about
this on one side of the boundary and not the other.

## How to apply

- Cancellation, timeouts, progress queries and health checks must not share a queue with the
  operation they observe or interrupt. Give cancellation its own queue, or the global one.
- Treat "the button logs something and then nothing happens" as evidence of a **queueing**
  problem, not a delivery problem, before reaching for the transport.
- Test it the way it actually fails: occupy the work queue exactly as a real run does, then
  assert the cancel still reaches its target within seconds.

```swift
let release = DispatchSemaphore(value: 0)
model.worker.async { release.wait() }     // occupy it as a write does
defer { release.signal() }
model.cancel()
wait(for: [reached], timeout: 2)          // seconds, not twenty minutes
```

  Reverting to `worker.async` fails this in 2 s while a cancel-with-nothing-running still
  passes — so it catches the real condition, not the existence of a cancel path.
- A cancel is only verified by a **real interrupted run**. Unit tests prove the message
  leaves; they do not prove the work stops.
