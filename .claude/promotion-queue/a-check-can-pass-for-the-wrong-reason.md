---
slug: a-check-can-pass-for-the-wrong-reason
origin: BootIt
session: bootit-2026-08-05-admin-gate-and-previews
date: 2026-08-05
target: spine
relevance: all — any suite where several cases assert the SAME expected value, especially negative or refusal cases
status: pending
reliability-target: L2
gate: test:bin/mutation-check.py --self-test
hook: Three self-test cases asserting "missing anchor", "ambiguous anchor" and "filter matches no tests" all expected NOT-APPLIED. A refactor moved the file they pointed at — and a missing file also returns NOT-APPLIED, so all three kept printing PASS while testing nothing but each other. Cases that share an expected value degrade into one case silently, and only the cases expecting something DIFFERENT can catch it.
---

## The lesson

BootIt's mutation harness has a `--self-test` that proves its own refusals work — the gate
for "a verdict you cannot believe must never be quieter than one you can". Seven cases,
five of them pointing at one real source file.

A refactor moved that file. CI went red on two cases. The other three printed:

```
PASS  a missing anchor is refused …        — Sources/BootIt/RunPlan.swift does not exist
PASS  an ambiguous anchor is refused        — Sources/BootIt/RunPlan.swift does not exist
PASS  a filter matching no tests is refused — Sources/BootIt/RunPlan.swift does not exist
```

Each of those asserts a **different** refusal. Each expects the **same verdict**. And the
broken fixture produces that verdict for a fourth reason entirely. So three independent
assertions collapsed into one, kept reporting PASS, and the detail line saying so was right
there and read as noise.

**Only the two cases whose expected value differed** — `NOT-COMPILED` and `SURVIVES` —
could fail. The suite was caught by its own minority.

## The general shape

Wherever N cases assert the same expected value, a single upstream breakage can satisfy all
N for a reason none of them is about. It is worst for **negative and refusal cases**,
because "rejected", "nil", "error", "not found" and "no-op" are exactly the values a broken
setup produces by default. A positive assertion fails loudly when its fixture rots; a
negative one starts passing harder.

Two defences, cheap:

1. **Assert the fixture before the cases.** Check the file/row/account the cases depend on
   actually exists, and refuse outright if not — naming which cases would otherwise pass
   hollow. A test that cannot run must not look like a test that ran.
2. **Read the reason, not the verdict.** If several cases pass with an identical detail
   string, they are one case wearing several names. Distinct reasons per case is the
   property; identical PASS lines are the smell.

## Applies when

Any refusal/validation suite, any parametrised negative test, any "these all return nil"
group — and immediately after any refactor that moves files a test suite names by path.
Path-named fixtures are the common trigger, but the failure is about shared expected values,
not about paths.
