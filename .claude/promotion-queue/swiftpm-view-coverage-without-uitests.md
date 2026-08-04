---
slug: swiftpm-view-coverage-without-uitests
origin: BootIt
session: bootit-v3.1.0-release-ui-redesign
date: 2026-08-01
target: profile:swift
relevance: any Swift app built as a SwiftPM package rather than an Xcode project
status: pending
reliability-target: L3
gate: test:mac/Tests/BootItTests/FlowTests.swift
hook: SwiftPM supports no XCUITest target, so "add UI tests" is not available — the coverage that matters comes from moving navigation and enablement logic OUT of View bodies, where it was never reachable in the first place.
---

## The lesson

BootIt had 14 tests covering parsing, formatting and the writer, and **zero** covering the
view layer. The reflex answer — "add UI tests" — does not exist on this stack:
**SwiftPM has no UI-testing target type.** XCUITest bundles require an Xcode project with a
host application. Getting one would have meant adding an `.xcodeproj` alongside a
hand-rolled `build.sh` and a CI workflow that both drive `swift build`, i.e. maintaining two
build systems to test a wizard.

The useful reframing: **most of what was untested was not view code at all.** It was
navigation, validation and button-enablement logic that merely *lived inside* a `View`:

```swift
// ContentView.swift — unreachable from any test
private func next() { … }
private func back() { … }
private var sourceValid: Bool { … }
```

Moved into a `FlowDecision` value plus derived properties on the model — with the
filesystem check injected as a parameter — the same logic became 19 tests that need no
window, no disk and no network. That immediately caught a real defect: one route through
the app skipped a step, which would have made a feature offered only on that step
unreachable for a whole class of users.

Two mutation checks confirmed the tests actually bite (preselect a drive → a test fails;
bypass the confirmation dialog → a test fails). Worth doing: a test suite nobody has tried
to break is a suite of unknown value.

## What this does NOT cover, and what to use instead

Genuine rendering — does the card look right, does dark mode work — stays uncovered.
**Snapshot testing is the wrong reach here:** it renders differently on a dev Mac than on a
`macos-15` runner and goes flaky on the first OS divergence. Use `#Preview` fixtures plus
one human screenshot round.

**Correction (2026-08-05):** as originally written this section said the fixtures "do
compile at a macOS 13 deployment target", and left the impression that compiling was the
thing to check. It is not. BootIt's ~40 fixtures compiled for four sessions and **never
rendered once** — on a SwiftPM package, previews fail unless a scheme exists with no
executable target in it, which needs a declared library product, not just a library target.
See [[preview-host-comes-from-the-scheme]]. Adopt this lesson's extraction advice, but do
not adopt "add `#Preview` fixtures" as though it were free: verify one renders before
writing forty.

## Applies when

A Swift target is a SwiftPM package and someone asks for view-layer coverage. Answer with
the extraction, not with an Xcode project — unless UI automation is genuinely required, in
which case the `.xcodeproj` cost is the real decision to put in front of the user.
