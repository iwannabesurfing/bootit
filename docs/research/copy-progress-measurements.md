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
| 1 | Do device `Bytes (Write)` and process `ri_diskio_byteswritten` diverge as Gemini predicts? *(settles D2)* | **OPEN** — needs an instrumented run; both columns are now recorded |
| 2 | Does the device counter over a full run land within a few percent of the payload? *(settles whether a denominator exists)* | **PARTIAL** — see M1 |
| 3 | Is the 33-minute tail transfer or flush? | **OPEN** |
| 4 | Do the counters survive device re-enumeration and sleep mid-run? *(ChatGPT's catch)* | **OPEN** — handled defensively regardless, see M2 |

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
