---
slug: check-an-artefact-against-its-own-timestamp
origin: BootIt
session: bootit-2026-08-05-admin-gate-and-previews
date: 2026-08-05
target: spine
relevance: all — any verification that inspects a build output rather than the build itself
status: pending
reliability-target: L4
gate: fdd-field
hook: `strings dist/App | grep -c PreviewRegistry` → 0 is a convincing result and says nothing about whether `dist/` holds the build you just made. A stale artefact answers every question about itself with total confidence, and relative paths make reaching the wrong one easy.
---

## The lesson

After restructuring BootIt into a library plus a thin executable, the check was whether the
release binary still excluded ~40 `#if DEBUG` preview fixtures:

```
strings dist/BootIt.app/Contents/MacOS/BootIt | grep -ci "PreviewRegistry" → 0
lipo -archs …                                                             → arm64
```

Clean, and nearly worthless. `dist/` is a relative path, the build had been run from a
different directory, and a `dist/` left by any earlier build would have produced exactly
those numbers. The verification and the thing verified were only assumed to be the same
object.

The fix costs one line:

```bash
ls -la dist/BootIt.app/Contents/MacOS/BootIt   # 08:04 — matches the build just run
date                                           # 08:04
```

## Why this one is easy to skip

Every incentive points the wrong way. The output is *about* the artefact, so it feels like
evidence about the artefact. The numbers are the ones you hoped for. And nothing errors —
a stale bundle is a perfectly valid file that answers every question put to it. Compare a
missing file, which fails loudly and gets fixed in seconds.

It is the same shape as reading a cached build's warning count, or a test run that silently
executed zero tests: **the check ran, the check passed, and the check was not pointed at the
subject.**

## What to do

- Prefer absolute paths, or resolve the artefact from the build command itself
  (`swift build --show-bin-path`, `cargo metadata`, the packager's own output line).
- Where that is not available, **stamp it**: compare the artefact's mtime against the build,
  or delete the output directory before building so a stale one cannot answer at all.
- In a receipt or a log, record *which* artefact was inspected, not just what was found.
  "0 preview symbols" is a claim; "0 preview symbols in the binary timestamped 08:04, built
  at 08:04" is evidence.

## Applies when

Any post-build inspection — symbol greps, architecture checks, bundle-content assertions,
size budgets, signature and notarisation checks — and especially when the inspection runs in
a different shell, directory or session from the build.
