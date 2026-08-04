---
slug: agent-built-ui-needs-a-screenshot-round
origin: BootIt
session: bootit-v3.1.0-release-ui-redesign
date: 2026-08-01
target: spine
relevance: all — any session where an agent builds or restructures user-facing UI it cannot see
status: pending
reliability-target: L4
gate: fdd-field
hook: Green tests plus a clean build say nothing about whether a screen is usable. Four presentation defects survived 52 passing tests and were visible in the first ten seconds a human ran the app — so budget one screenshot round BEFORE calling UI work done, and say plainly which claims are intent rather than observation.
---

## The lesson

A full UI restructure shipped with 52 green tests, SwiftLint strict clean, a successful
release build and a confirmed app launch. All true, and all beside the point: the agent
could not screenshot the window (accessibility permission not granted, pyobjc absent), so
every visual claim was **intent, not observation**.

The first real run produced four defects that no test could have caught, because none of
them is a logic error:

1. The phase that **failed** rendered as an orange "in progress" dot — a stopped build
   looked like it was still working.
2. After a failure the footer offered a **disabled Cancel and nothing else**, stranding the
   user on a dead primary action.
3. **Two different percentages sat on one line** (the status text's own figure beside the
   overall figure), which simply read as broken.
4. A toolbar icon read as a **hamburger menu** and duplicated a labelled control directly
   below it.

The same run also surfaced a functional bug the agent had no way to hit — `diskutil -69850`
on a drive carrying a prior bootable layout — and a units defect (`bytesHuman` dividing by
1024 while labelling the result "GB") that only became visible when a real drive's size
could be compared against Disk Utility's.

## Why this is a process lesson, not a "test more" lesson

The gap is not coverage. It is that **presentation has no assertion surface**: hierarchy,
emptiness, whether a control's affordance reads correctly, whether two numbers next to each
other confuse. Adding tests would not have found any of the four.

The cheap, high-yield move is a **screenshot round**: build, hand it over, ask for shots of
the states that matter, fix what the shots show. In this session that round cost one message
and produced six fixes, several of them safety-relevant.

## How to apply

- When finishing UI an agent cannot see, **state explicitly which claims are unverified** —
  "it builds, launches and does not crash" is a different claim from "it looks right".
- Ask for screenshots of the *awkward* states, not the happy path: failure, empty list,
  several similar items, mid-operation.
- Prefer preview fixtures for those states so they are reachable without hardware — but
  treat previews as a way to *reach* the state, not as evidence anyone looked at it.
- Carry the same honesty into the close: VoiceOver, keyboard-only and dark mode remain
  unverified unless a human drove them.
