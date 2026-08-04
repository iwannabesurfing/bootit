---
slug: a-mutation-check-must-verify-its-own-build
origin: BootIt
session: bootit-2026-08-04-copy-progress
date: 2026-08-04
target: spine
relevance: all — any project using mutation testing to prove a test bites, which is the standard way of proving it
status: pending
reliability-target: L2
gate: test:bin/mutation-check.py --self-test
hook: A mutation check that does not assert the mutated tree compiles cannot tell a broken mutation from a surviving one. BootIt's harness reported SURVIVES for a mutation whose patch had silently failed to apply — which reads as "this test does not bite" and would have justified deleting a test that bites perfectly well. Every survival result from an unverified harness is worthless, and it fails in the direction that destroys good tests.
---

## The lesson

Mutation testing is the standard answer to *"is this test real, or does it pass no matter what?"* —
break a line, confirm a test fails. The harness is usually a few lines of shell:

```sh
patch_the_source
out=$(run_tests | grep "failed")
[ -z "$out" ] && echo "SURVIVES" || echo "caught"
restore_the_source
```

This has a silent failure mode. If `patch_the_source` doesn't apply — a string that didn't match, a
bad index, a typo in the replacement — the tests run against **unmutated** code, pass, and the
harness prints `SURVIVES`.

That happened. A Python inline-patch had a malformed expression, produced a no-op, and the harness
reported that the `clearHandlers()` mutation survived. Re-run with the patch verified, the same test
failed on the same mutation with a clear message.

## Why this direction of failure is the dangerous one

The two possible errors are not symmetric:

- **False "caught"** — you believe a test bites when it doesn't. Bad, but it leaves a test in place.
- **False "survives"** — you believe a test is inert when it is load-bearing. **The natural next
  action is to delete or rewrite that test**, removing real coverage on the grounds of evidence that
  was never gathered.

An unverified harness fails toward the second one, because a patch that fails to apply always
produces green tests, which always looks like survival.

Compounding it: a broken mutation is *more* likely on exactly the code worth mutating. The delicate
patches — multi-line bodies, indentation-sensitive replacements, anything matched by index rather
than by a unique string — are the ones targeting complex logic, which is where a load-bearing test is
most likely to live.

## How to apply

Assert three things between mutating and believing anything:

1. **The patch applied** — `assert old in text` before replacing, and diff the file afterwards.
   A `str.replace` that matches nothing returns the original string without complaint.
2. **The mutated tree builds** — a mutation that breaks the build makes every test "fail", which
   looks like `caught` and is equally uninformative. Fail the harness loudly on a build error rather
   than scoring it.
3. **The restore worked** — diff against the backup at the end. A half-restored file quietly
   poisons every subsequent mutation in the same batch.

Prefer `assert`-guarded exact-string replacement over index arithmetic, and run one mutation at a
time against a pristine copy.

## Receipt

BootIt, 2026-08-04, during the fast-follow for an independent review. First run: `❌ M8
clearHandlers no-op — SURVIVES`. The patch script contained a dead `if False else t` expression
followed by index-based splicing that did not modify the target. Re-run with the patched body
printed and the build checked (`build errors: 0`), the same mutation produced
`XCTAssertEqual failed: ("2") is not equal to ("1") - a sample arriving after the run ended must not
reach it`. Nine mutation checks were run across the session; this was the only one whose first
result was wrong, and it was wrong in the direction that would have deleted a good test.
