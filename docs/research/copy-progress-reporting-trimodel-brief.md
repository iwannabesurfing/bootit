# TRI-MODEL brief — BootIt — how a 38-minute opaque copy phase should report progress

**Status:** BRIEF (model-NEUTRAL — full context + the questions, ZERO leading answers; brief neutrality is
the gate's L4 residue). The SAME brief goes verbatim to every model. Capture each pass as a leg; commit a
synthesis the FDD cites. ≥3 independent models (add never drop). See `/tri-model` skill.

## 0. The decision under triangulation

**What should BootIt's UI report to the user during a ~38-minute operation whose underlying tool
emits no usable progress information for ~33 of those minutes?**

This is a direction decision about the *surface*, not only a question of which API to read. It
covers what is displayed, what it is derived from, how it behaves when the derivation is unavailable
or untrustworthy, and how the choice can be validated before shipping.

## 1. Context the models need

### The product

BootIt is a macOS (Apple Silicon, macOS 13+) SwiftUI app that creates bootable USB installer drives
for macOS and Windows. It is a step-through wizard. The screen under discussion is the one shown
while the installer is being written: a circular percentage ring, a status line, a phase checklist,
a collapsible log, and a Cancel button.

### The constraint that shapes everything

For the macOS path, the actual work is performed by **Apple's own `createinstallmedia` binary**,
shipped inside `Install macOS <name>.app`. BootIt shells out to it from a privileged LaunchDaemon and
streams its stdout/stderr. BootIt **cannot modify, replace, or reimplement** this tool — Apple does
not document or support any alternative, and hand-rolling the installer-media layout is out of scope.

`createinstallmedia`'s complete output for a full run, verbatim from a real macOS 26.6 (Tahoe) run:

```
Erasing disk: 0%... 10%... 20%... 30%... 100%
Copying essential files...
Copying the macOS RecoveryOS...
Making disk bootable...
Install media now available at "/Volumes/Install macOS Tahoe"
```

Five lines for a 38-minute operation. Only the first carries percentages, and it covers the erase,
which completes in seconds. After printing `Making disk bootable...` the process blocks for roughly
30 minutes and prints nothing further until the final line.

### Our own measured data (from a full instrumented run, 2026-08-03)

| Fact | Measurement |
|---|---|
| Total wall clock | 38 min (`createinstallmedia` 20:29:47 → ~21:07) |
| Payload | ~20 GB on disk (from an 18.37 GB `SharedSupport.dmg`) |
| Sustained throughput | ~8.8 MB/s average; ~535 MB/min |
| Target device | SanDisk USB flash, 61.5 GB, reported by `diskutil` as "3.2Gen1" |
| Filesystem on target | JHFS+ (required by `createinstallmedia`), GPT |
| Process state during the long phase | `U` — uninterruptible sleep, blocked on I/O |
| Process CPU during the long phase | 0.0–0.3% |

Sampled once per minute, the destination volume's `df` figures behaved like this:

| Time | `df` used | Device I/O observed |
|---|---|---|
| 20:31 | 1.13 GB | — |
| 20:33 | 2.06 GB | — |
| 20:34 | **18.71 GB** | +16.65 GB in 60 s |
| 20:34 → 21:07 (33 min) | **18.71 GB, unchanged** | steady ~535 MB/min |

16.65 GB cannot cross a ~9 MB/s link in 60 seconds. Both `used` and `avail` froze for the remaining
33 minutes while the device demonstrably kept accepting data.

Separately measured: `iostat -Id disk4` (per-device cumulative counters) showed continuous movement
throughout the 33 minutes `df` was frozen — 535 MB in a sampled 60-second window. Two caveats we
have not resolved: those counters are **device-wide, not per-process**, and **cumulative since
boot**, so establishing a per-run baseline is an open problem. We also observed that sampling
windows shorter than ~30 s misreported the rate badly (a 4-second window read 1–3.5 MB/s against a
true ~9 MB/s), because the writes are bursty.

### Design lineage — three prior attempts, all shipped, all wrong

**This surface has been "fixed" three times. Each fix addressed the mechanism that had just failed
and inherited the same blind spot from a new direction. Any proposal that amounts to a fourth
substitution of the same kind should be evaluated against why the first three failed.**

1. **Parse percentages from the tool's output — read the first match per line.**
   `createinstallmedia` rewrites one line in place and keeps appending, so a line reads
   `Erasing disk: 0%... 10%... 20%...`. Reading the first match reported 0% for the whole run.
   *Fixed by reading the last match instead.*

2. **Parse percentages from the tool's output — read the last match.**
   Correct for the erase, useless overall: the copy phase emits **no percentages at all**, so the
   bar sat still for the entire long phase. *Fixed by abandoning output-parsing for the copy and
   polling bytes on the destination volume instead — "measured, not parsed", which was believed at
   the time to be the durable answer.*

3. **Poll the destination volume's used-bytes (`df`).**
   The current shipped behaviour, and the subject of the table above. HFS+ allocates the file at
   full size up front and fills the blocks in behind it, so `df` reports the allocation immediately.
   The ring reaches ~95% in four minutes and then does not move for the remaining 33. To a user this
   is indistinguishable from a hang; on the instrumented run the operator asked twice whether it had
   frozen. It had not — half a gigabyte per minute was landing.

A fourth candidate (per-device I/O counters) has been proposed internally but not implemented, and
its two caveats above are unresolved. It is listed here as context, not as a preferred answer.

### Other relevant constraints

- **Verification is expensive and human-gated.** Falsifying any progress design requires a real
  ~40-minute write to physical media, performed by a person. This is why three wrong answers each
  survived to ship.
- **The status line has the same problem as the ring.** It showed `Making the drive bootable…`
  unchanged for 33 minutes — technically accurate (the tool had reached that step and was blocked
  waiting for data to become durable) but operationally indistinguishable from a stall.
- **A stated estimate is currently wrong.** BootIt logs "this takes 10–20 minutes" against a
  measured 38.
- **Throughput is device-dependent and varies widely.** ~8.8 MB/s was measured on this stick; a
  faster drive could complete the same payload in a few minutes. Any time-based approach has to
  cope with an order-of-magnitude spread.
- **Cancel must remain responsive and honest.** While the process is in uninterruptible sleep a
  signal is not delivered until it returns from the current syscall.
- The app also has a Windows path which writes files itself (not via an opaque third-party tool) and
  *does* have real per-file progress available. Whether the two paths should present progress the
  same way is in scope.

## 2. The questions

1. On macOS, what mechanisms exist to determine how many bytes a specific child process has
   durably written to a specific removable volume, and what are the accuracy, permission, and
   stability characteristics of each? Consider that BootIt's writer runs as root in a LaunchDaemon.
2. The measured behaviour shows `df` reporting allocation rather than written data. Under what
   circumstances does that happen, and are there filesystem-level or device-level queries that
   distinguish the two?
3. Given the tool provides no progress signal for ~87% of the runtime, what should this screen
   display during that period? Evaluate the options you consider viable, including any not listed
   in this brief.
4. What are the arguments for and against showing a percentage at all in this situation, and what
   would you need to believe for each position to be correct?
5. If a percentage is shown and its underlying signal later proves unreliable, how should the UI
   degrade? What should it do differently from what it does today?
6. How should a design like this be validated before shipping, given that falsification currently
   requires a 40-minute human-performed hardware run? What cheaper tests would meaningfully reduce
   the risk of a fourth wrong answer?
7. Three prior fixes each replaced the *reader* of a progress signal. What, if anything, does that
   pattern suggest about where the error actually lies?
8. What would make you reject each of the candidate mechanisms outright — device I/O counters,
   `fs_usage`, filesystem polling, time-and-throughput estimation, or output parsing?
9. Are there approaches that sidestep the measurement problem entirely — changing what the
   operation is, how it is invoked, or what the user is asked to wait for?
10. What is the failure mode of your recommended approach, and how would a user or a developer
    detect that it had failed?

## 3. What a good answer contains

- A clear recommended **direction** for what this surface reports, with the reasoning that leads to
  it — not only an API selection.
- Concrete specifics: what is sampled, at what interval, what is displayed, and what the fallback is.
- Explicit statement of **what it rejects** and why, including any of the four prior/candidate
  mechanisms.
- **How it fails**, and how that failure would be noticed.
- Where it depends on assumptions we have not measured, say so and name the measurement that would
  settle it.
