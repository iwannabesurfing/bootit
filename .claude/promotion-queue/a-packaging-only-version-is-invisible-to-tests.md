---
slug: a-packaging-only-version-is-invisible-to-tests
origin: BootIt
session: bootit-2026-08-05-v3.4.0-release
date: 2026-08-05
target: spine
relevance: all — any project whose shipped version/build metadata lives in a file the build tool does not read (Info.plist beside SwiftPM, a manifest beside a bundler, a chart value beside a compiler)
status: pending
reliability-target: L4
gate: none
gate-detail: the property is the ABSENCE of a gate — no test can assert a value the build graph never reads, which is the whole finding. The check is a post-assembly read-back, recorded in the run receipt rather than in the suite.
hook: A version string that only the packaging script reads is invisible to every test you have. Bumping it changes nothing the suite can observe, so a fully green run says exactly as much about a correct bump as about a forgotten one — and the artefact is where the value first becomes real.
---

## The lesson

BootIt's shipped version lives in `mac/Info.plist`. SwiftPM never reads it: `build.sh` copies it
into the bundle after `swift build` is done. So the 241-test suite, the ThreadSanitizer run, the
strict lint and the mutation corpus are **all blind to it**. A release-day tree with the version
un-bumped, half-bumped, or bumped to the wrong number is green in exactly the same way as a correct
one.

This generalises past Info.plist. The same hole exists wherever the value that identifies what
shipped sits outside the build graph the tests exercise — a `package.json` version a bundler stamps
in, a Helm chart's `appVersion`, a Dockerfile label, an `AndroidManifest` value injected by Gradle.

## What actually catches it

Two things, and only after assembly:

1. **A read-back from the artefact**, not from the source file. Build the bundle and print the value
   out of the *built* thing:

   ```
   ./build.sh && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
       dist/BootIt.app/Contents/Info.plist        # → 3.4.0
   ```

   Read from the artefact's own timestamp too, or a stale `dist/` from last week will answer with
   the same confidence — see [[check-an-artefact-against-its-own-timestamp]].

2. **A cross-check in CI against a second source of truth.** BootIt's release workflow refuses to
   run when the tag and `Info.plist` disagree. That is the only automated gate on the value, and it
   fires at tag time — after the branch has been green for however long.

## Why the gap is easy to defend and still wrong

It is tempting to say the CI tag check covers it. It covers *disagreement between two values*, not
*correctness of either*: tag `v3.4.0` against a plist saying `3.4.0` passes whether or not that is
the version you meant to ship. And it fires only on a tag, so nothing between releases notices.

The honest position is that this class of value is verified by **assembling and reading back**, and
that belongs in the release run receipt rather than in the test suite — writing a test that parses
a plist the build never consumes tests the parser, not the product.

## Applies when

Release preparation on any stack. Ask one question before tagging: *which of the values that
identify this release does the test suite actually read?* Whatever the answer excludes has to be
read back out of the built artefact by hand, once, before the tag goes up. Pairs with
[[publish-gated-on-a-secret-succeeds-silently]] — that one is about the artefact not existing, this
one is about the artefact existing and being mislabelled.
