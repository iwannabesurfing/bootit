# TRI-MODEL synthesis — BootIt — how a 38-minute opaque copy phase should report progress

**Status:** SYNTHESIS. Reconciles the 3 legs against the brief + our own data.
Per the gate: converged → DECIDE; diverged → RESOLVE (not silently pick), our measured data as the
cross-check. The FDD cites this. Numbers are device-tune seeds.

**Legs:** Claude Opus 5 (native) · Gemini (Thinking) · ChatGPT (Medium reasoning) · 2026-08-03
**Fired because:** the surface has been "fixed" three times, each fix shipped wrong, and each could
only be falsified by a 40-minute human-gated hardware run. Raised by the user after the third failure.

---

## 0. Headline (what all models led with)

**All three independently rejected the framing, not just the implementation.** None of them led with
"use API X". Each led with a version of the same sentence:

- **Claude:** "a category error: the app kept answering *what percentage is done* when the user was
  asking *is this still working*."
- **Gemini:** "the fundamental flaw across the three previous shipping designs was not choosing the
  wrong reader — it was treating an asynchronous, multi-buffered kernel operation as a linear,
  real-time single process." It names the shape: a **reader substitution anti-pattern**.
- **ChatGPT:** "the central design error was not repeatedly choosing the wrong reader. It was
  assuming that every long operation must be represented as a scalar fraction complete."

Three models, three fresh contexts, one conclusion: **the bug was never in the reader.** That is the
single most important output of this pass, and it retroactively condemns the fourth patch that was
queued as task #7 before this gate ran.

## 1. UNANIMOUS — decided

| # | Decision | Basis |
|---|---|---|
| 1 | **`df`/filesystem allocation polling is rejected as a progress source.** | All three, same mechanism: JHFS+ pre-allocates the file extents, so `statvfs` jumps to full size before the data exists. Confirmed by our own 2026-08-03 trace (+16.65 GB in 60 s at ~9 MB/s). |
| 2 | **Output parsing is rejected.** | `createinstallmedia` emits nothing during the 33-minute phase. Exhausted by shipped attempts 1 and 2. |
| 3 | **Fixed time estimates are rejected.** | Device throughput spans ~5 MB/s to ~400 MB/s. Any constant misinforms by an order of magnitude — this is the existing "10–20 minutes" defect. |
| 4 | **`fs_usage` / kernel tracing is rejected for production.** | All three: undocumented human-facing output, fragile across OS versions, SIP exposure. Lab instrumentation only. |
| 5 | **Per-device block-I/O counters are the best available signal**, sampled against a **per-run baseline** captured at phase start. | All three. Also settles the brief's "no clean baseline" worry — all three treat baseline subtraction as trivial. That objection was mine and it was wrong. |
| 6 | **Liveness must be displayed explicitly and separately from any completion figure.** | All three, independently. Throughput (MB/s) + bytes transferred. **This is what BootIt has never had, and it is the actual fix for the reported symptom.** |
| 7 | **Never reach 100% before the process exits successfully.** | Claude and Gemini explicit (Gemini: clamp to 95%); ChatGPT implicit via "substantial finalisation work". Already correct in current code — keep it. |
| 8 | **Validation must move off physical hardware: record traces, replay them offline.** | All three, unprompted, plus a throttled fake-writer harness. See §5. |
| 9 | **Cancel must tell the truth during uninterruptible sleep.** | Gemini and ChatGPT explicit: a SIGTERM to a process in state `U` is not delivered until it returns from the syscall, so the UI must say "waiting for the drive to respond" rather than appear to ignore the click. |

## 2. DIVERGENCES — resolved

### D1. Should macOS show a percentage at all? *(the core decision)*

| Leg | Position |
|---|---|
| **Claude** | Keep it. The payload size is known and bytes-to-device are measurable, so a real ratio exists; refusing to compute it is over-correction. Must degrade honestly. |
| **Gemini** | Keep it, under "strict mathematical guardrails": 0–5% erase, 5–95% hardware delta, 95–100% reserved for process exit. |
| **ChatGPT** | **Reject it for macOS, for now.** Indeterminate activity ring + elapsed + a broad empirical range. Counters as liveness only, never converted to a percentage. Specifies the exact evidence bar that would justify re-introducing one. |

**Resolution — ChatGPT's position is adopted, sequenced.** This is not the 2–1 vote; a vote would be
the wrong instrument. The resolution turns on our own measured data:

ChatGPT's bar for approving a percentage requires a value that "remains accurate across slow flash,
fast flash, external SSD, USB hubs, and supported macOS versions" and "does not hit 90–99%
substantially before completion". **We have exactly one instrumented run, on one SanDisk stick,
n = 1.** We have never measured whether device-written bytes track the payload within a useful margin
on any second device. On our own evidence the bar is not met, so a percentage today would again be a
claim we cannot support — which is precisely the failure this gate was convened to stop.

Note the three positions are closer than they appear: all three agree the percentage must never be
the only evidence of life, must never complete early, and must degrade when its input goes bad.
The live disagreement is only whether the **denominator is trustworthy today**. It is not, yet.

So: **ship the honest design now, and let it earn the percentage.** The instrumentation that makes
the indeterminate design safe is the same instrumentation that produces the evidence for a later
determinate one. This is sequencing, not permanent rejection — and Gemini's 5/90/5 model is the
design we adopt *if and when* the evidence clears the bar.

### D2. Is `proc_pid_rusage` → `ri_diskio_byteswritten` usable?

| Leg | Position |
|---|---|
| **Claude** | Recommended as a per-process cross-check, immune to device-wide contamination. |
| **Gemini** | **Rejected.** It measures writes into the kernel's Unified Buffer Cache, not physical flash — it would hit 20 GB in ~2 minutes and then freeze. *The same failure mode as `df`, one layer up.* |
| **ChatGPT** | "May count logical I/O submitted through the filesystem rather than bytes made durable." Worth instrumenting as a **second liveness signal**; would not ship a percentage from it without tracing what the counter represents on every supported macOS version. |

**Resolution — my own leg is corrected.** Gemini and ChatGPT converge, with a mechanistically specific
argument I did not account for: the per-process counter and the device counter measure **different
layers** (VFS/cache vs block device). If Gemini is right, using it as a "cross-check" would generate
spurious divergence alarms, because the two *should* disagree.

Demoted to: **instrument and observe, never drive UI from it until measured.** This is cheap to
settle — one instrumented run logging both counters side by side answers it definitively, and it is
listed in §5 as a required measurement.

### D3. Should the Windows path look the same as the macOS path?

| Leg | Position |
|---|---|
| **Gemini** | Same visual layout (ring + throughput + status) on both, driven by file counts on Windows and IOKit delta on macOS. |
| **ChatGPT** | Keep Windows determinate — BootIt controls and measures that work. "Making the two paths visually identical would discard useful truth merely for consistency." |
| **Claude** | Did not address. |

**Resolution — both, because they are not actually in conflict.** Gemini is talking about *layout*,
ChatGPT about *fidelity*. Adopt a common component set (ring, throughput line, status line) with
**honest per-path fidelity**: Windows determinate because the work is genuinely measured; macOS
indeterminate-with-liveness during the opaque phase. Consistency of furniture, not of claims.

## 3. THE SYNTHESISED MODEL — the decision

**macOS write phase:**

1. **Determinate** while `createinstallmedia` emits real percentages (the erase, 0→5%).
2. **Indeterminate activity ring** for the opaque phase — animated, not a frozen number.
3. **Liveness line, always present and always derived from measured device bytes:**
   current throughput (MB/s) and bytes written this run.
4. **Elapsed time** plus a **broad empirical range** ("typically 15–45 minutes on USB flash"), never
   a countdown.
5. **Three distinguishable states**, stated in words: *writing* · *no recent device activity* ·
   *finishing / flushing*. The third is a real state — our run ends with the tool blocked in `U` while
   data drains.
6. **Explicit degradation:** if the counter is missing, resets, or contradicts itself, say so and drop
   to elapsed-only. Change the *kind of claim*, never freeze the old one.
7. **Cancel** reports "waiting for the drive to respond" while the process is in uninterruptible sleep.
8. **100% only on exit code 0.**
9. Retire the "10–20 minutes" log line.

**Windows write phase:** unchanged determinate percentage, same visual furniture.

## 4. What each model uniquely caught

- **Gemini** — the exact filesystem mechanism (`F_PREALLOCATE` / bulk extent allocation on JHFS+);
  the layered diagram that explains *why* process-level counters fail where device-level ones work;
  the USB-disconnect failure mode with IOKit device-node disappearance as its detector; the throttled
  loopback-device harness; and the U-state cancel wording.
- **ChatGPT** — the **four-properties framing**: no available mechanism provides process attribution,
  volume attribution, byte accuracy *and* durability simultaneously, and "that absence is the main
  fact the UI must respect". Also the falsifiable evidence bar for re-approving a percentage; that
  **counters can reset on device detach, re-enumeration, or sleep** (a direct threat to baseline
  subtraction that neither other leg caught); and that write amplification, retries and metadata mean
  transferred bytes ≠ payload bytes, so a known payload is not automatically a valid denominator.
- **Claude** — the liveness/completion split as the organising frame; and the **mutation check**:
  replay the 2026-08-03 trace through the *old* `df`-based implementation and assert it reproduces
  the frozen-at-95% pathology, so the fixture proves the fix rather than merely accompanying it.

## 5. Build / sequencing implications + open dials

**Sequence:**

1. **Instrument first.** Log a per-run trace: timestamp, device `Bytes (Write)`, process
   `ri_diskio_byteswritten`, tool output line. Cheap, four columns, ships behind a flag.
2. **Build the replay harness** and make the progress state machine a **pure function** of the trace.
   Commit the 2026-08-03 trace as fixture #1. Include the mutation check from §4.
3. **Ship the indeterminate + liveness design** (§3). It is safe on n = 1 evidence.
4. **Collect traces across a device matrix** — slow flash, fast flash, external SSD, through a hub.
5. **Re-evaluate the percentage against ChatGPT's bar.** If device bytes track payload within a
   useful margin across the matrix, adopt Gemini's 5/90/5 model. This is a real decision point, not a
   formality.

**Required measurements (each settles something currently unknown):**

- Do device `Bytes (Write)` and process `ri_diskio_byteswritten` diverge as Gemini predicts? *(settles D2)*
- Does the device counter over a full run land within a few percent of the payload, or is write
  amplification material? *(settles whether a denominator exists at all)*
- Is the 33-minute tail transfer or flush? Our trace shows steady 535 MB/min, which suggests transfer,
  but `U` state at ~0% CPU is also consistent with a long flush. Changes the status wording.
- Do the counters survive device re-enumeration and sleep mid-run? *(ChatGPT's unique catch; threatens
  the baseline)*

**Open dials (device-tune seeds):** sample interval 2–5 s · rate window 30 s (our 4-second sample read
1–3.5 MB/s against a true ~9 MB/s — too short is not merely noisy, it produced a nearly-actioned false
"stalled" call) · no-activity threshold 60–120 s · duration range copy "15–45 minutes".
