---
slug: an-unestablished-reading-is-not-a-negative-one
origin: BootIt
session: bootit-2026-08-05-admin-gate-and-previews
date: 2026-08-05
target: spine
relevance: all — any UI or logic driven by a reading of the environment (permissions, entitlements, group membership, connectivity, device capability)
status: pending
reliability-target: L2
gate: test:mac/Tests/BootItTests/AdminRightsTests.swift
hook: A check that reads the environment has three answers, not two — yes, no, and "could not establish" — and collapsing the third into "no" fails in the confident direction. BootIt's administrator check returns nil when the directory will not answer, because a failed reading rendered as a warning would tell administrators to go and find an administrator.
---

## The lesson

BootIt warns a standard macOS account that it cannot approve the privileged helper, before
it downloads ~14 GB it will not be able to use. The reading behind that warning is `admin`
group membership, and it can fail: an unresolvable user, a directory service that will not
answer, a truncated group list.

`Bool` has no room for that, and the tempting signature is the wrong one:

```swift
static func isAdministrator(user: String) -> Bool      // ✗ what does false mean?
static func isAdministrator(user: String) -> Bool?     // ✓ nil is "did not establish"
```

Every caller then treats nil as **silence**, not as a finding:

```swift
func warnsAboutAdministrator(platform: Platform?) -> Bool {
    platform == .macos && isAdministrator == false     // not `!= true`
}
```

The difference is one operator and it is the whole lesson. `!= true` warns on nil, which
means a failed reading tells an administrator they are not an administrator and sends them
looking for a second account that does not exist. `== false` says nothing until it knows
something.

A mutation pins it — swapping `== false` for `!= true` fails a test that asserts a nil
reading produces no warning. Without that test the operator is a one-character edit nobody
would question in review.

## Which direction to fail

Pick the direction by what the wrong answer costs, and say so at the call site:

- **A warning, a nudge, a degraded-mode banner** → fail to **silence**. A false alarm is
  paid by every user with a flaky environment; a missed one is paid by the users who were
  going to hit the wall anyway, slightly later.
- **A guard on something destructive or irreversible** → fail to **refuse**. Not knowing
  whether it is safe is not permission to proceed.

The mistake is not choosing wrongly, it is not choosing — a `Bool` return has already made
the decision, invisibly, in favour of whichever value the failure path happens to produce.

## Applies when

Any permission probe, capability check, entitlement read, feature-detect or reachability
test whose result drives what the user is told. If the reading can fail, the type must be
able to say so, and every branch must decide what silence means.
