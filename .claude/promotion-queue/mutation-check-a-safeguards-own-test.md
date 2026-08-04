---
slug: mutation-check-a-safeguards-own-test
origin: BootIt
session: bootit-2026-08-03-phase-0
date: 2026-08-03
target: spine
relevance: all — any session that adds a defensive safeguard against framework or platform behaviour
status: pending
reliability-target: L4
gate: fdd-field
hook: A test written alongside a defensive safeguard must be mutation-checked by deleting the safeguard. If the test still passes, the safeguard is guarding nothing and the test is asserting the framework's behaviour, not yours — both should go, and the comment that justified them is a falsehood you were about to leave in the codebase.
---

## The lesson

Converting BootIt's XPC replies from a magic string prefix to `NSError`, the agent added what
looked like diligence: explicit class whitelisting on both sides of the connection, a
carefully-worded comment explaining why it was necessary, and a test proving it was in place.

```swift
/// `NSError` is **not** among the property-list classes XPC allows in a reply by
/// default, so every reply that can carry one has to whitelist it explicitly —
/// and on *both* sides. Get it wrong on either and the call fails at the
/// boundary, not anywhere you can put a breakpoint.
```

Confident, specific, plausible, and **wrong**.

The routine mutation check — delete the safeguard, confirm the test fails — showed the test
**passing** with the whitelisting removed. A ten-line probe against the real framework settled
it: a reply parameter typed `NSError?` already gets `NSError` in its allowed set, inferred
from the signature.

Removed: the whitelisting, the test, and the comment. What replaced the comment is the
constraint that *is* real — an `NSError`'s `userInfo` values must themselves be allowed
classes.

## Why this class of thing survives

A safeguard against framework behaviour and a test asserting that same behaviour are
**mutually reinforcing and jointly unfalsifiable**. The test passes, so the safeguard looks
justified; the safeguard exists, so the test looks meaningful. Nothing in a green suite
distinguishes "my code does the right thing" from "the framework was always going to do this".

Worse, the false comment is the durable artefact. Code gets deleted; a confident sentence
about how a platform works gets *read and believed* by whoever touches it next.

## How to apply

- Every test written in the same change as the safeguard it covers gets one mutation check:
  **delete the safeguard, re-run, confirm red.** A test that stays green is testing the
  platform.
- When about to write "the framework does not do X by default" in a comment, **measure it** —
  a scratch binary that prints the actual default costs a minute and either confirms the
  comment or deletes a fiction.
- Prefer deleting a redundant safeguard to keeping it "for clarity". A no-op dressed as a
  precaution teaches the next reader something untrue.
- The same applies to defensive nil-checks, retry wrappers and belt-and-braces validation:
  if removing it changes no test, either the test is missing or the code is.
