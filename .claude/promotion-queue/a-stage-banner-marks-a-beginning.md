---
slug: a-stage-banner-marks-a-beginning
origin: BootIt
session: bootit-2026-08-05-copy-progress-correction
date: 2026-08-05
target: spine
relevance: all — any UI or automation whose progress is driven by parsing a subprocess's stage announcements (installers, imagers, packagers, migrations, CI tools)
status: pending
reliability-target: L4
gate: test:mac/Tests/BootItTests/RecordedRunTests.swift
hook: A tool prints "Making disk bootable" when it ENTERS that stage, not when it finishes the previous one — and a stage can contain most of the work. BootIt read that line as "the end is near" and showed 95%; measured across two full runs it arrives at 17.9% and 14.7%, with 87% of the bytes still to write. A banner's wording describes what is starting; it says nothing about what remains.
---

## The lesson

Stage banners are **entry announcements**. `Making disk bootable...`, `Finalising...`,
`Cleaning up...`, `Optimising...` — every one of them is printed at the top of a block whose
duration is unknown to the reader, and reassuring words are not correlated with small blocks.

BootIt's measurement, from two complete `createinstallmedia` runs recorded end to end:

| | banner at | run total | share |
|---|---|---|---|
| 2026-08-04 | 309.1 s | 1728.4 s | **17.9%** |
| 2026-08-05 | 264.0 s | 1800.6 s | **14.7%** |

At the 2026-08-05 banner the device had written **2.85 GB of 21.26 GB — 13.4%**. The screen showed
95%, and held it for 25.6 of the run's 30 minutes. A person watching asked the question that found
it: *"if it's making the drive bootable, why is it still copying?"*

Worse, the tool's own ordering was not what the wording implies: the bulk copy line
(`Copying to disk: …`) is emitted **after** `Making disk bootable`. The banners are not a timeline.

## How to apply

- **Timestamp every banner against the bytes/items that followed it** before letting any of them
  drive a bar. One recorded run gives you the table above; it is the whole analysis.
- Treat a banner as a **label for a state**, never as a **position in a sequence**. Wording is safe;
  arithmetic is not.
- If a banner must imply nearness, require it in **every** recorded trace at a late fraction —
  BootIt's replacement (`Copying to disk` + `100%`) lands at 90.4% and 91.4%, and the assertion runs
  over all committed traces so a third run can break it.
- Beware the sticky flag. BootIt's "finishing" latch, once set, could not clear — so a single
  mis-timed banner mislabels the entire remainder rather than a moment.

## Applies when

Any long subprocess whose UI is driven by output parsing. The failure is invisible in tests, because
a hand-written transcript orders the lines the way the author *believes* the tool behaves — BootIt's
"verbatim" test transcript was missing the one line that refuted its own comment. Pairs with
[[a-bound-becomes-a-value-when-transcribed]] (where the 95% came from) and
[[pipe-buffering-reads-as-silence]] (why the real percentages were never seen).
