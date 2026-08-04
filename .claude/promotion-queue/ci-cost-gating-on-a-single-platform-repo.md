---
slug: ci-cost-gating-on-a-single-platform-repo
origin: BootIt
session: bootit-2026-08-03-phase-0
date: 2026-08-03
target: spine
relevance: all — any repo whose only supported platform is an expensive CI runner (macOS, Windows, GPU)
status: pending
reliability-target: L4
gate: fdd-field
hook: "Gate the expensive platform build to release events" is the right CI-cost rule for a repo where the expensive runner is one leg of several. It is the wrong rule where that runner is the ONLY platform — gating removes the default branch's sole pre-release signal. The lever that actually exists there is paths-ignore for doc-only commits.
---

## The lesson

A CI cost gate flagged BootIt's `build-test-lint` job: `runs-on: macos-15` with no `if:`, so
an expensive runner spins on every trigger. The prescription was **clause 2: gate the
expensive platform build to release events**.

Correct arithmetic, wrong repo. BootIt is an Apple Silicon SwiftPM app — the build, the tests
and SwiftLint all need the Apple toolchain. There is no cheap leg to fall back to. Applying
the rule would not have moved work to a cheaper runner; it would have deleted the only
build/test/lint signal `main` gets before a release.

That mattered concretely: this repo had already shipped a release whose main feature path
could not work.

What was actually available was a different lever entirely. Roughly a third of the commits in
the pending push were session-log and README edits, each spinning a full macOS build for
files the job never reads:

```yaml
push:
  branches: [main]
  paths-ignore: ['**/*.md', '.claude/**', 'LICENSE']
```

Real saving, no signal lost. The finding was left open and advisory with the reasoning
recorded in the workflow, rather than silenced.

## How to apply

- Before applying a cost rule, ask **what the cheap alternative actually is**. If the answer
  is "there isn't one, this platform is the product", the rule's premise does not hold.
- On single-platform repos the levers are: `paths-ignore` for files CI never reads,
  `concurrency` with `cancel-in-progress`, caching the slow install steps, and matrix
  trimming. Not trigger-gating.
- When declining a gate's prescription, **write the reason where the next reader will hit
  it** — in the workflow file, not only in a session log — and leave the finding open rather
  than suppressing it.
- Beware gates whose wording encodes an assumption about repo shape. "Gate the expensive
  build" silently assumes a cheap build exists.
