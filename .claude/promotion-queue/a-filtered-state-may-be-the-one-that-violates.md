---
slug: a-filtered-state-may-be-the-one-that-violates
origin: BootIt
session: bootit-2026-08-05-copy-progress-correction
date: 2026-08-05
target: spine
relevance: all — any assertion that filters, skips or excludes a subset before checking a property (test filters, allowlists in lints, "known exceptions" in audits)
status: pending
reliability-target: L4
gate: test:mac/Tests/BootItTests/RecordedRunTests.swift
hook: A test asserted "the ring never claims a percentage", having first filtered out the one state that claimed one. The filter was not a bug — it was written deliberately, because that state was known to behave differently. Which is precisely why it needed asserting. An exclusion added so a test can pass is an exclusion around the defect.
---

## The lesson

```swift
let opaque = states.filter {
    if case .finishing = $0.activity { return false }   // ← the exemption
    return true
}
XCTAssertTrue(opaque.allSatisfy { $0.fraction == nil },
              "a percentage here is a claim nothing in this trace supports")
```

The property is right. The message is right. It ran against a real 865-sample trace. And it could
not fail, because the single state that returned a percentage was the single state removed before
the check.

The exemption was written honestly: `.finishing` *did* behave differently, on purpose, at the time.
The author excluded a known exception rather than weakening the assertion — which feels like the
careful choice, and is the exact move that makes the assertion decorative.

## The tell

**The filter and the defect are described by the same words.** "The ring never claims a percentage
*except when finishing*" and "the ring wrongly claims a percentage *when finishing*" are the same
sentence with one word changed. When an exclusion clause names the same case a bug report would
name, the exclusion is load-bearing and nobody is testing it.

Two more of the same shape in the same repo, same week:

- A "verbatim" transcript test whose transcript was **missing the line** that refuted the comment
  above it — an exclusion by omission rather than by filter.
- A test proving a `df`-driven bar hits 99% at 310 s, sitting in the same file as a shipped bar
  driven from a banner at 309.1 s. The same instant, condemned in one instrument and shipped in the
  other, because neither test looked at both.

## How to apply

- **For every filter in an assertion, write the sentence "this test does not check X".** If that
  sentence would embarrass you in a bug report, delete the filter and fix the code.
- **Prefer narrowing the property to excluding the data.** "Fraction is nil for all states" is
  checkable; "for all states except the interesting one" is not.
- **Assert the excluded case somewhere.** An exemption with no test of its own is an untested branch
  wearing a test's clothing.
- **Mutate it.** BootIt's fix is guarded by three mutations that restore each old behaviour and must
  turn a test red. A filtered assertion cannot be mutation-killed, which is the mechanical detector.

## Applies when

Test suites, lint allowlists, audit scopes, security review exclusions — anywhere a known exception
is carved out so the general rule can be stated cleanly. Cousin of
[[a-check-can-pass-for-the-wrong-reason]]: that one is several cases collapsing into one silently,
this one is a single case being explicitly waved through. Both end with a green suite certifying a
property it is not exercising.
