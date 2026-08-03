# TRI-MODEL leg — Claude (native)

**Model:** Claude Opus 5 (1M context) · **Date:** 2026-08-03 · **Brief:** `copy-progress-reporting-trimodel-brief.md`

---

## Headline

**The three prior failures were not measurement failures. They were a category error: the app kept
answering "what percentage is done?" when the user was asking "is this still working?"**

Every fix so far replaced the *source* of a percentage. None supplied evidence of **liveness** — an
independently-derived signal that motion is occurring right now. That is why the current failure is
worse than the arithmetic error suggests: a bar frozen at 95% next to a status line frozen at "Making
the drive bootable…" contains *zero bits* about whether the machine is working or wedged. The operator
on the instrumented run asked twice whether it had stalled. It had not. Nothing on screen could
distinguish the two states, and no improvement to percentage accuracy alone would have changed that.

So the recommended direction separates two claims BootIt has been conflating:

- **Liveness — must be exact, must never be inferred from the percentage.** Bytes/second and bytes
  transferred, measured at the device, updated every few seconds.
- **Completion estimate — allowed to be approximate, must degrade honestly.** A percentage, but one
  permitted to say "I don't know" rather than freeze at a number.

## 1. Correcting a claim in the brief

The brief lists device I/O counters with two caveats, one of which is wrong:

> *"cumulative-since-boot so no clean baseline"*

Not an unresolved problem. **Snapshot the counter when the write begins and subtract.** The absolute
origin is irrelevant; only the delta matters. This was raised as a blocker in the session that
produced the brief and it was overstated — a monotonic counter with a start-of-run baseline is the
textbook shape for this measurement.

The *real* caveat is the other one: the counters are **device-wide**, so any other writer to the same
device contaminates them. Here the target is a dedicated USB stick the daemon holds an exclusive claim
on, so contamination is limited to OS background activity (Spotlight, `fseventsd`) — small against
20 GB, and biased in one direction only (over-counting, so the bar runs ahead, never stalls).

## 2. Signal analysis

Both recommended mechanisms were verified against this machine's SDK and IORegistry, not assumed.

| Signal | What it actually measures | Verdict |
|---|---|---|
| `statfs`/`df` used-bytes | **Allocation.** HFS+ preallocates the destination extents, so it reports full size long before the data exists. | **Rejected** — this is the shipped bug. |
| `statfs` avail-bytes | The same allocation event, inverted. Froze identically. | **Rejected** — no independent information. |
| IOKit `IOBlockStorageDriver` → `Statistics` → `Bytes (Write)` | Bytes accepted by the **block device**. Verified present via `ioreg` on this machine. Readable through IOKit; no need to shell out to `iostat`. | **Recommended primary.** Device-wide; needs a start-of-run baseline. |
| `proc_pid_rusage(pid, RUSAGE_INFO_V2+)` → `ri_diskio_byteswritten` | Bytes written by **a specific process**. Confirmed in `sys/resource.h` (`RUSAGE_INFO_V2`…`V6`). | **Recommended cross-check.** Per-process, immune to device contamination — but counts writes to *all* devices. |
| `fs_usage` | Syscall trace. Root-only, undocumented human-readable output, a debugging tool Apple may change freely. | **Rejected** — fragile to parse, inappropriate to ship. |
| Output parsing | Five lines in 38 minutes, none during the long phase. | **Rejected** — exhausted; attempts 1 and 2. |
| Time + assumed throughput | Throughput varies by an order of magnitude across devices; a fixed constant is the "10–20 minutes" line that is already wrong. | **Rejected as primary**; *measured* throughput is legitimate — see §3. |

The two recommended signals are **independent of each other** (device-side, process-side), which
matters more than either being perfect: they cross-check at runtime, and disagreement is information.

## 3. Recommended direction

**Drive the estimate from measured bytes; display liveness separately and unconditionally.**

1. **Baseline at start.** Record `Bytes (Write)` for the target device immediately before launching
   `createinstallmedia`.
2. **Sample every 2 s, compute the rate over a 30 s trailing window.** The measured run showed
   4-second windows reading 1–3.5 MB/s against a true ~9 MB/s because flash writes are bursty. A short
   window is not merely noisy — it produced a nearly-actioned false "it has stalled" call.
3. **Percentage = (bytes written − baseline) / expected payload**, the payload derived from the source
   `SharedSupport.dmg` size as it already is. Approximate — block-device bytes include filesystem and
   journal overhead — so present it as an estimate, not a measurement.
4. **Always show liveness regardless of the percentage:** current throughput and bytes transferred.
   This answers the question the user is actually asking, and comes free from the same samples.
5. **Time remaining from measured throughput**, not a constant. At 8.8 MB/s with 20 GB that reads
   ~38 min; on a fast SSD ~3. Recompute continuously; it self-corrects.
6. **Degrade honestly.** If the counter has not moved for a defined interval (say 60 s) while the
   process is alive, do not freeze and say nothing — state it: *"No data written in the last minute —
   still waiting on the drive."* True in the stall case **and** the flush case, and far more useful
   than a stationary 95%.
7. **Retire the "10–20 minutes" constant.**

### Why not abandon the percentage entirely

A defensible position, considered seriously — an honest indeterminate spinner plus elapsed and
throughput is never *wrong*. Rejected as primary because the payload size **is known in advance** and
bytes-to-device **is measurable**, so a genuine ratio exists; refusing to compute a ratio you can
actually compute is over-correction from three bad ratios. But the fallback in point 6 is exactly this
design, and it should engage whenever the ratio's inputs stop being trustworthy.

## 4. The validation problem — the part that actually prevents a fourth wrong answer

Question 6 is the most important one in the brief, and where the effort belongs.

Three wrong answers shipped **because each could only be falsified by a 40-minute human-gated hardware
run**, so none was falsified before release. Any recommendation that does not change this property is
likely to become the fourth.

**Record progress traces and replay them in tests.** The instrumented run already produced one: a
minute-by-minute series of `df` values and device counters across a full 38-minute write. That trace
is a fixture. Concretely:

- Have the daemon write a trace file (timestamp, device bytes, process bytes, tool output line) on
  every run, behind a flag.
- Commit traces from real runs as test fixtures.
- Make the progress computation a **pure function** of (elapsed, samples, expected payload) so a trace
  can drive it with no hardware, no daemon, no USB stick.
- Assert the properties that matter, which are *not* "the percentage is correct":
  - **monotonic** — never goes backwards;
  - **never stalls silently** — for any trace where bytes are moving, the displayed state must change;
  - **reaches ~100% at the end**, and does not arrive early;
  - **the 2026-08-03 trace fails the old implementation.** This is the mutation check: replay it
    through the `df`-based function and assert it reproduces the frozen-at-95% pathology. A test that
    reproduces the known failure is the only proof the new design fixes it.

This converts a 40-minute human-gated hardware test into a sub-second unit test, and is the single
highest-value item in this pass. It is also cheap — the trace format is four columns.

Secondary cheap tests: run against a slow disk image or a throttled loopback device to exercise the
low-throughput path without physical media.

## 5. On question 7 — what the pattern means

Three fixes each replaced the reader. That suggests the team treated this as an *implementation*
problem when it is a *specification* problem. Nobody had written down what the progress indicator is
required to communicate, so each fix optimised the only property anyone had named — the number — and
no fix was ever tested against the property that was actually failing: "the user can tell it is still
working."

Generalised: when the same user-visible symptom survives two fixes, stop improving the mechanism and
write down what the surface is required to say. Then test *that*.

## 6. How this recommendation fails

- **Device-wide contamination.** Heavy unrelated I/O to the same device inflates the count; the bar
  runs ahead, finishes early, then waits. Detectable by cross-checking `ri_diskio_byteswritten` for
  the child; on divergence beyond a threshold, prefer the per-process number.
- **The expected-payload denominator is wrong.** The ratio is only as good as it. Today it is a 1.1×
  multiplier on the DMG size calibrated against one run; a different macOS layout could shift it.
  Mitigation: cap the bar short of 100% and let the tool's final output line complete it — which the
  current code already does correctly.
- **`ri_diskio_byteswritten` includes non-target writes.** If the tool writes scratch data to the
  internal disk, the per-process figure over-counts. Hence cross-check, not primary.
- **A future macOS changes the copy strategy** so block-device bytes no longer track payload progress.
  Detected by trace fixtures failing on a new OS — provided traces are captured routinely, which is
  the point of §4.

## 7. What I would want measured before locking this

- Whether `Bytes (Write)` for the target over a full run lands within a few percent of the payload, or
  carries substantial filesystem overhead. One instrumented run answers it.
- Whether `ri_diskio_byteswritten` for the child tracks the device counter closely. If it does, prefer
  it — per-process is strictly better when accurate.
- Whether the 33-minute tail is genuinely transfer or a final flush of cached data. The steady
  535 MB/min suggests transfer; uninterruptible sleep at ~0% CPU is also consistent with a long flush.
  This changes nothing in the recommendation (both are real work, both measurable at the device) but
  it would sharpen the status wording.
