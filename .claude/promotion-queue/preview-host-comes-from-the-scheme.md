---
slug: preview-host-comes-from-the-scheme
origin: BootIt
session: bootit-2026-08-05-admin-gate-and-previews
date: 2026-08-05
target: profile:swift
relevance: any SwiftUI app built as a SwiftPM package rather than an Xcode project
status: pending
reliability-target: L4
gate: fdd-field
hook: "Move the views into a library target" is the standard advice for making `#Preview` work in a SwiftPM package, and on its own it does nothing. Xcode resolves the preview HOST from the selected scheme, not from the target the view lives in — so a library file previewed under a scheme containing an executable still fails, and the error still names the executable. The fix needs a library *product* too, so a scheme exists with no executable in it.
---

## The lesson

BootIt carried ~40 `#Preview` fixtures for four sessions. **None of them had ever
rendered.** Opening any view file gave:

> Cannot preview in this file — the executable target "BootIt" needs the build setting
> "ENABLE_PREVIEWS" set to "YES".

Which cannot be set from `Package.swift`. The queued fix was the widely-repeated one: move
the views into a library target and leave a thin `@main` executable over it.

**That would not have worked, and the refactor touched 21 test imports and 11 mutation
anchors.** It was cheap to find out first: a five-line probe view was dropped into an
existing library target and previewed. Same error — *still naming the executable target*,
for a file that was not in it.

Three arrangements, measured on Xcode 26.6:

| View's target | Scheme | Renders? |
|---|---|---|
| executable | `<Package>` | no |
| **library** | `<Package>` | **no** — error still names the executable |
| **library** | **library-only** | **yes** |

The host is resolved from the **scheme**. The package scheme contains every target, so it
finds the executable and tries to host previews in it. A library target only helps once a
scheme exists that has no executable in it at all — which for a SwiftPM package means
declaring a **library product**:

```swift
products: [
    .library(name: "AppKit_", targets: ["AppKit_"]),   // <- the scheme that previews
    .executable(name: "App", targets: ["App"])         // naming any product suppresses
]                                                       //   the implicit ones — list all
```

## Why it is worth the probe

The failure mode is a refactor that looks principled, is recommended everywhere, passes
every test, and does not fix the thing it was done for. The probe cost one throwaway file
and five minutes; it would have cost a full restructure to learn the same thing afterwards,
by which point the sunk cost argues for keeping it.

Put the probe in a target the tool has **already built**. A brand-new target reports
`"Probe.swift" not found in any targets` — an answer about the index, not about previews,
and easy to misread as a verdict.

## Applies when

Any SwiftPM package whose previews do not render, and any plan whose step is "move it into
a library target so previews work". Verify the scheme, not just the target — and verify it
before paying for the move.
