# Copy progress — measurement record

Where the evidence lands for the questions
[`copy-progress-reporting-trimodel-synthesis.md`](copy-progress-reporting-trimodel-synthesis.md)
§5 left open. The synthesis decided **no macOS percentage for now**, sequenced: collect traces
across a device matrix, then re-evaluate against ChatGPT's evidence bar (§D1).

This file is the ledger for that. It is deliberately separate from the synthesis, which is a
record of what three models concluded on 2026-08-03 and should not be edited after the fact.

**Standing caveat: n = 1 device.** Everything below is one SanDisk 3.2Gen1 stick on one Mac.
The bar in §D1 requires slow flash, fast flash, external SSD and a hub. None of that is met.

---

## The §5 questions

| # | Question | Status |
|---|---|---|
| 1 | Do device `Bytes (Write)` and process `ri_diskio_byteswritten` diverge as Gemini predicts? *(settles D2)* | **CLOSED — prediction falsified.** They tracked each other all run, ending 1.2% apart. See M4. |
| 2 | Does the device counter over a full run land within a few percent of the payload? *(settles whether a denominator exists)* | **CLOSED** — 1.048 with a measured baseline. See M4; baseline in M3, earlier estimate in M1. |
| 3 | Is the 33-minute tail transfer or flush? | **CLOSED — transfer.** 1.5 GB written at 9.2 MB/s *after* the tool printed 100%. See M4. |
| 4 | Do the counters survive device re-enumeration and sleep mid-run? *(ChatGPT's catch)* | **CLOSED — sleep yes, replug no.** They are different hazards; only one needs handling. See M5. |

---

## M1 — device bytes vs payload landed, whole run

**2026-08-04**, read from the 2026-08-03 stick, still attached and never unmounted since the run.

| Measure | Value | Source |
|---|---|---|
| Device `Bytes (Write)`, cumulative | 21,266,141,696 (21.266 GB) | `ioreg -c IOBlockStorageDriver` |
| Payload on the volume | 20,105,474,048 (20.105 GB) | `diskutil info disk4s2` |
| **Ratio** | **1.058** | |
| `Operations (Write)` | 34,188 | |
| `Total Time (Write)` | 2,780 s (46.3 min) | |

**Reading:** device-written bytes exceeded payload by ~5.8% on this run. Write amplification
is therefore **not** disqualifying — ChatGPT's concern that "transferred bytes ≠ payload bytes"
is real but small here.

**The direction matters and it is the bad one.** The numerator (device bytes) runs *ahead* of
a payload denominator, so a naive `deviceBytes / payload` would reach 100% about 6% before the
copy finished — the exact "hits 90–99% substantially before completion" failure ChatGPT's bar
names. Gemini's 95% clamp is not decoration; it is load-bearing.

**Confidence: LOW-MEDIUM.** Two things are assumed, not measured:
- **The baseline is assumed ≈ 0.** The counter is cumulative for the life of the device
  attachment. Machine uptime was 2 days and the run was the evening before, so it is *likely*
  the stick was attached fresh for the run — but nothing recorded the counter at run start.
  That is precisely what the new instrumentation fixes.
- The erase's own writes are inside this total and are not separated out.

The next instrumented run supersedes this entirely, with a real baseline.

## M2 — counter noise on an idle mounted volume

**2026-08-04.** Same stick, idle, nothing writing to it deliberately.

| Interval | Δ `Bytes (Write)` | Implied rate |
|---|---|---|
| ~2 min | 0 | 0 |
| ~10 min | 164,864 B | **~275 B/s** |

**Reading:** the counter has **no process attribution** — this is the mounted volume's own
journal, and it is indistinguishable from BootIt's writes at the counter.

**This changed the design.** `CopyProgressModel` originally treated *any* increase as the drive
moving, which meant a drive that had genuinely wedged — but was still mounted — would never be
reported as wedged, because the journal kept resetting the silence clock. There is now a
`movementFloor` of 1 MB. At the measured ~9 MB/s that is 0.11 s of real writing, so it cannot
mask a working drive; at 275 B/s the journal needs an hour to clear it.

Caught by reading the counter twice ten minutes apart, not by reasoning about it. It would have
survived every unit test written at the time.

**Confidence: MEDIUM.** One device, one filesystem (JHFS+), volume idle rather than under other
load. A busier volume, or a different filesystem, will have a different floor — but the floor
only has to sit between "journal noise" and "a working copy", and those are four orders of
magnitude apart.

---

## M3 — what the counter reads on a freshly attached drive

**2026-08-04, session 2.** The stick from M1/M2 was unplugged and plugged back in. Read once,
immediately, before anything was asked to write to it.

| Reading | Value |
|---|---|
| `Bytes (Write)` | **871,936 B** (~0.87 MB) |
| `Operations (Write)` | **59** |

**Reading: a freshly attached drive does not start at zero.** Mounting it is itself a write —
journal replay and the volume's own mount bookkeeping — and `IOBlockStorageDriver`'s counter is
per-device and cumulative from attach, with no process attribution to separate that from ours.

**This is question 2's baseline, measured rather than assumed**, which is the gap M1 named as
the reason its own confidence was only LOW-MEDIUM: *"the baseline at run start is assumed, not
measured."* It is no longer assumed.

The magnitude is not the point — 0.87 MB against a ~21 GB run is 0.004%, and rounds away.
**The shape is the point.** Code that assumed a zero origin would be wrong by whatever the mount
happened to cost, and that quantity is a property of the drive and its filesystem state, not a
constant anybody can hard-code. A drive that was not cleanly unmounted has a journal to replay
and will read higher. Sampling the baseline at the start of the run is therefore load-bearing,
and `CopyProgressModel` subtracting it is not defensive tidiness — two mutation checks pin it.

**Confidence: HIGH** for the claim being made (the origin is non-zero and must be sampled).
**LOW** for the specific figure, which is one drive, one filesystem, one mount, and should not
be treated as a typical value.

---

## M4 — the first instrumented run, end to end

**2026-08-04, session 2.** A complete `createinstallmedia` write to the same 61.5 GB stick,
recorded by the shipping app with no special build. **865 samples over 28.8 minutes.** The trace
is committed as `mac/Tests/BootItTests/Fixtures/copy-run-2026-08-04.jsonl` and replayed by
`RecordedRunTests`, so every figure below is now a test rather than a note.

| Quantity | Value |
|---|---|
| Duration of the copy phase | 1728 s (28.8 min) |
| Device bytes written (baseline subtracted) | 21.069 GB |
| Process bytes (`proc_pid_rusage`) | 20.829 GB |
| Payload landed (`statfs`) | 20.105 GB |
| device / payload | **1.048** |
| device / process | **1.012** |

### Question 1 — falsified

The tri-model D2 prediction, from two of three legs, was that `ri_diskio_byteswritten` counts
writes into the unified buffer cache: it would sprint to the payload size in about two minutes
and then freeze, reproducing the `df` failure one layer up.

**It did not.** It stayed within ~20% of the device counter from the moment bulk copying began
and finished 1.2% below it. On this hardware it would have worked as a numerator.

**This does not reopen the percentage.** The reason the app shows none is that the *denominator*
is not knowable before the run — `createinstallmedia` does not announce how much it intends to
write, and the amount that lands is not the amount the device writes. A second well-behaved
numerator supplies no denominator. The decision stands; one of its supporting arguments does not,
and saying so is the point of having measured it.

**Confidence: HIGH** for this device and this macOS build. **One run, one drive** — the
prediction may well hold on hardware where the cache behaves differently, which is exactly why
the column is still recorded and still never displayed.

### Question 2 — 1.048, and the direction is the dangerous one

M1 estimated 1.058 from an assumed baseline; with the baseline measured (M3) it is 1.048. Either
way the device writes ~5% more than lands, so a payload-sized denominator reaches 100% with
about 5% of the work outstanding. Gemini's 95% clamp was load-bearing for that design. The
shipped design needs no clamp because it claims no percentage.

### Question 3 — transfer, not flush

`createinstallmedia` printed `Copying to disk: 0%… 100%` at **1562 s** and the run ended at
**1728 s**. In those 166 seconds the drive wrote **1519 MB at 9.2 MB/s** — a working rate, not a
flush and not a hang.

So the tool's own "100%" had a sixteenth of the writing still to come. Any bar driven from the
tool's output would have sat at 100% for nearly three minutes.

### What the filesystem column did — the bug, recorded at last

`volumeUsedBytes` reaches **99.9% of its final value at 310 s**, which is **18% of the way
through** the run. At that instant the device had written **12.7%** of what it would write and
**23.6 minutes remained**. It then does not move for over fifteen minutes.

This is the defect that shipped three times, and this is the first time it has been captured
rather than inferred. It is not a rounding or tuning problem and no clamp rescues it: `df` is
measuring something that finishes long before the drive does.

**The 20.8-minute silence** between 309 s and 1562 s — `createinstallmedia` emitting nothing at
all — is the stretch the feature exists for. The device counter moved in 612 of 625 samples
across it, so the liveness display had something true to say for essentially all of it.

---

## M5 — sleep and re-enumeration, the last open question

**2026-08-04, session 2.** Same stick, measured directly rather than during a write — the hazard
is a property of the counter, not of a copy in flight, so this needed five minutes rather than
another forty-minute run.

| Event | `Bytes (Write)` before | after | Verdict |
|---|---|---|---|
| Unplug, plug back in | 21,261,767,168 | **99,840** | **Resets** |
| Sleep, wake, drive left attached | 99,840 | **247,808** | **Survives** |

**They are not the same hazard, and only one needs handling.** The counter lives on the
`IOBlockStorageDriver` instance. Sleeping does not destroy it, so the count continues
monotonically across a wake — the only trace is ~148 KB of flush-and-remount bookkeeping, well
under the 1 MB `movementFloor` from M2, so it cannot make an idle drive look busy. Unplugging
destroys the instance, and the replacement starts from zero.

**ChatGPT's leg raised this and the other two did not.** It was handled defensively with no
evidence either hazard was real. One is, and the handling is right: on a backwards reading
`CopyProgressModel` rebases, gives up the run total **permanently**, and keeps throughput — a rate
needs two adjacent samples, a total needs an origin. Reporting 99,840 bytes written after 21 GB
had already landed would be a bar running backwards. Now pinned by `CounterHazardTests` and a
mutation check.

### The baseline varies by an order of magnitude

M3 measured 871,936 bytes / 59 operations on attach. This attach cost **99,840 bytes / 4
operations** — the difference being that the drive was cleanly ejected first, so there was no
journal to replay. M3's "LOW confidence for the specific figure" was right: the origin is not
just non-zero, it depends on how the drive was last detached. Nothing may hard-code it.

---

## What is now instrumented

Every run writes `~/Library/Logs/BootIt/copy-trace-<UTC>.jsonl`, one JSON object per sample,
sampled every 2 s, pruned after 30 days. Columns:

| Column | Why it is there |
|---|---|
| `elapsed` | monotonic seconds since the copy phase started |
| `deviceBytes` | `IOBlockStorageDriver` `Bytes (Write)` — **the signal the UI uses** |
| `processBytes` | `proc_pid_rusage` — recorded to be disproved (question 1) |
| `volumeUsedBytes` | `statfs` — the control column, the reader that froze |
| `line` | the tool's own output, so a trace replays as one sequence |

`CopyProgressModel.replay(_:)` turns a trace into the exact display states the app would have
shown. A trace is therefore a test, and a wrong answer is falsifiable in milliseconds instead
of by a 40-minute human-gated write — which is the reason three wrong answers shipped.

**To settle question 1**, one instrumented run is enough: plot `deviceBytes` against
`processBytes`. If Gemini is right, `processBytes` races to the payload size in ~2 minutes and
then flatlines, while `deviceBytes` climbs steadily. **To settle question 2 properly**, the same
run gives a real baseline. **Question 3** needs the tail inspected for whether `deviceBytes`
is still climbing during it — the 2026-08-03 table says it was (535 MB/min throughout), which
points at transfer rather than flush, but that was sampled by hand.
