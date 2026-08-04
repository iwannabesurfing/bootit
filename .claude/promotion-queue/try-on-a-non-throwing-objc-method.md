---
slug: try-on-a-non-throwing-objc-method
origin: BootIt
session: bootit-2026-08-03-phase-0
date: 2026-08-03
target: profile:swift
relevance: swift — any Swift code wrapping an Objective-C API in do/catch, especially a security check
status: pending
reliability-target: L2
gate: build-setting:-warnings-as-errors
hook: `try` on a non-throwing Objective-C method compiles with only a warning, so a do/catch around it reads as an enforcement check while the catch can never execute. BootIt carried two of these around `NSXPCConnection.setCodeSigningRequirement` — one logging "rejected a connection failing the signing requirement", one throwing "the helper failed its signature check", neither reachable.
---

## The lesson

Both halves of BootIt's XPC security model looked like this:

```swift
// The whole security model of this daemon.
do {
    try connection.setCodeSigningRequirement(HelperInfo.clientRequirement)
} catch {
    NSLog("BootItHelper: rejected a connection failing the signing requirement: \(error)")
    return false
}
```

`-[NSXPCConnection setCodeSigningRequirement:]` returns `void`. It is not a throwing API. So
the `catch` — and the `return false` that reads as the rejection — could never run. Swift
permits `try` on a non-throwing expression with a warning rather than an error, and the
warning had been sitting in the build output unread.

**The security was intact.** XPC registers the requirement and invalidates a failing
connection itself, asynchronously. That is what actually enforces this. But the code
described a synchronous check at a line that performs no check, which is the kind of comment
someone later relies on.

Also lost in the fiction: a *malformed* requirement string raises an uncatchable
`NSInvalidArgumentException` — a crash, not the logged rejection the code promised. The catch
never covered the one failure mode it plausibly could have.

## How to apply

- Treat **"no calls to throwing functions occur within 'try' expression"** as an error-grade
  signal, not noise. It means a `catch` block in your source is dead — and dead `catch`
  blocks around security or validation calls actively mislead.
- Turn warnings on and keep the build at zero. These two survived because the routine check
  was `swift build 2>&1 | grep error:`.
- When wrapping an ObjC API, check the header for `NSError **` or `NS_SWIFT_THROWS` before
  writing `do/catch`. Void-returning ObjC methods signal failure by exception or by
  side-effect, and neither is catchable Swift error handling.
- Write the comment about **where enforcement actually happens**. For `NSXPCConnection` that
  is the connection's invalidation, not the setter — so the honest place for the
  failure-handling story is `invalidationHandler`.
