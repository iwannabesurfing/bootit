---
slug: progress-from-used-bytes-measures-allocation
origin: BootIt
session: bootit-2026-08-03-release
date: 2026-08-03
target: spine
relevance: all — any long copy, download, restore or export whose progress is inferred from a destination's size
status: pending
reliability-target: L3
gate: test:mac/Tests/BootItTests/RecordedRunTests.swift
hook: A progress bar driven from filesystem used-bytes measures ALLOCATION, not data. BootIt's ring reached 95% in four minutes and then did not move for the remaining 33 of a 38-minute write, while the device took a steady 535 MB/min throughout — the filesystem reports the allocation up front, and both `used` and `avail` then freeze. Cumulative device I/O counters tracked the real write the whole time.
---

## The lesson

A copy-progress bar had already been fixed twice. First it read the *first* percentage in a line
that gets rewritten in place, so it reported 0% forever. Then it was found that the tool prints no
percentages at all during the long phase, so output-parsing was abandoned in favour of polling
bytes on the destination volume — measured, not parsed, which felt like the durable answer.

The first full run against that fix produced this:

| Time | `df` used | device I/O |
|---|---|---|
| 20:31 | 1.13 GB | — |
| 20:33 | 2.06 GB | — |
| 20:34 | **18.71 GB** | +16.65 GB in 60 s |
| 20:34 → 21:07 | **18.71 GB, frozen** | steady 535 MB/min |

16.65 GB did not cross a ~9 MB/s USB link in sixty seconds. The filesystem had **allocated** the
file at full size and was filling the blocks in behind it. `df` reports the allocation the moment
it happens, so the bar raced to 95% in four minutes and then sat there for 87% of the wall clock,
next to a status line that also never changed.

To the user this is indistinguishable from a hang — they asked twice whether it was stuck, which
is the real measure of the defect. It was not stuck; half a gigabyte a minute was landing.

## Why it fails silently

Every layer is telling the truth about something. The filesystem is honest about allocation. The
tool is honest that it reached its final step. The bar is honest about the number it was given.
Nothing errors, and on a *fast* destination the lie is invisible — allocation and completion happen
close enough together that the bar looks fine. The defect only appears when the destination is slow
enough for the gap to open, which is precisely when a user most needs the progress to be real.

Note also the shape: this is the **third distinct cause of the same symptom**. Each fix addressed
the mechanism that had just failed and inherited the same blind spot from a new direction. That the
symptom recurs is the signal that the *source of truth* was never right, not the parsing of it.

## How to apply

- **Never infer copy progress from a destination's reported size** — `df`, `stat`, directory
  walks, `FileManager` attributes. They report allocation and metadata, not durable bytes.
- Read the **device's cumulative I/O counters** instead (`iostat -Id <dev>`, or the platform
  equivalent). They tracked the real write accurately for the entire 33 minutes that `used` was
  frozen, and they are the only source that stayed truthful.
- Sample over **at least 30–60 seconds** before drawing conclusions about throughput. Short
  windows caught idle gaps in bursty flash writes and read as 1–3 MB/s against a true 9 MB/s —
  enough to nearly justify a false "it has stalled" call.
- When the same user-visible symptom returns after a fix, suspect the **source of truth**, not the
  reader. Two fixes to the reader is the signal.
- If no honest progress signal exists, say so in the UI — elapsed time plus measured throughput
  beats a frozen percentage, and a stated "this can take 30+ minutes on a slow drive" beats both.
