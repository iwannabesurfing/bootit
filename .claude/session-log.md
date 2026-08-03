# BootIt — session log

## 2026-08-03 (session 2) — v3.2.0 shipped, and the progress bar lied for 33 minutes

**Commits:** `26f20f7` → `8231f8b` (5 this session), all pushed. Tag **`v3.2.0`**, released
2026-08-03T10:29:01Z.

**CI:** green, SHA-anchored to `8231f8b` (run `30779906756`, `headSha` verified equal to
`git rev-parse HEAD`).
**Local:** receipt `.claude/receipts/bootit-green.build-test-lint.receipt.txt` —
**143 tests, 0 failures**, 0 SwiftLint violations across 34 files, 0 compiler warnings.
(110 tests at session start.)

### The headline

**v3.2.0 is published and notarised**, replacing a release that had been on GitHub since 31 July
shipping a macOS path that could not work. Verified by downloading from the public
`releases/latest/download/BootIt.dmg` URL rather than by trusting the workflow: `spctl` reports
`source=Notarized Developer ID` for both the DMG and the app inside it, and the bundle reports 3.2.0.

Then the first full `createinstallmedia` write against this build — 38 minutes, verified good —
showed that **the progress ring measures allocation, not data**. It reached 95% in four minutes and
did not move again for the remaining 33.

### Phase 1 closed — items 1 and 3

- **Item 3 — `call()`, invalidation and cancel are tested** (9 tests), driven through the real
  `erase()` path against an injectable proxy, so `call()` is exercised as the app uses it rather
  than through a hole opened for testing. The only seam is where the daemon comes from.
- **Item 1 — one erase instead of two.** `DiskErase` owns the arguments and the −69850 retry; each
  caller keeps its own runner, since the daemon streams through a cancellable `ToolRunner` and the
  app blocks on `Shell.run` — the one thing they genuinely do differently.

### The hang the test seam found

Writing the tests found a bug rather than confirming their absence. `call()` obtained the XPC proxy
**before** registering the in-flight signal. A connection dying in that window found `inFlight` still
nil, so it had nothing to signal, and the failure it recorded was then wiped by the registration
itself. The call went out on a dead connection whose reply can never arrive — and the wait is
untimed, deliberately, because a real write legitimately runs 40 minutes. **The window was small;
the consequence was unbounded.**

Registering first closes it. A `defer` releases the claim on every exit including a throwing
`proxy()`, which previously left `isBusy` stuck on and Remove Helper refusing for the life of the
process.

Three mutation checks, all bite: the old order hangs the call until the test times out; deleting the
`defer` strands the busy flag; a `connectionFailed` that records without signalling parks the write
forever.

### Three diagnostics bugs, one shape

All three were the app deciding what a failure *meant* instead of reporting what it was *told* —
the same shape as last session's dead `catch` blocks and the `"NEEDS_FULL_DISK_ACCESS: "` prefix.

- **"USB access blocked" was asserted for a test that never reached the helper.** Nothing had been
  established in either direction. There are three outcomes now — ok, blocked, inconclusive — and an
  unreachable helper is inconclusive whatever the app itself can do, as is having no drive inserted.
- **`helperError` was computed and discarded.** On the run that exposed this it would have read "the
  helper stopped unexpectedly", which points straight at the cause. Instead the screen offered Full
  Disk Access as the fix for a problem that had nothing to do with it.
- **`helperDenial` was computed and discarded too.** The daemon separates a TCC denial
  (`needsFullDiskAccess`) from a read-only volume or an I/O error (`operationFailed` + strerror), and
  both rendered as the identical "go and add Full Disk Access". It also made the day's verification
  weaker than it looked: nothing on screen distinguished which code had crossed, so the
  classification had to be inferred from reading the daemon rather than observed.

### Verification ran the wrong binary for an hour

The first "Test USB Access" reported failure. It was not a bug in the shipped code: the **running app
had started at 10:36 and the installed bundle was written at 10:56**, so a pre-`NSError` app was
talking to a post-`NSError` helper. The unified log named it exactly — a method-signature dump
comparing `class 'NSString'` against `argument 1: type encoding (@) '@"NSError"'`, then
`XPC_ERROR_CONNECTION_INTERRUPTED`.

Three measurements agreed: the `ea0bbe2` commit time (10:56), the bundle mtime (10:56), and the app
process start time (10:36:13). Rebuilt, reinstalled, relaunched — then both halves passed.

**`isStale()` cannot catch this.** It detects a stale *daemon* by fingerprint, and in this case
actively reported healthy: the running app hashes the on-disk helper and compares it to the running
daemon, and both were new. The only stale party was the one asking. Nothing detects an app whose
bundle was replaced underneath it.

### The release, and the secrets that had vanished

The six signing secrets were **gone** — `total_count: 0`, no environments, no org. They had existed
on 31 July, proven by the published v3.1.0 DMG reporting `source=Notarized Developer ID`.

This mattered more than a plain blocker: the publish step is gated on
`if: ... && env.MACOS_CERT_P12 != ''`, so tagging would have checked out, built, signed ad-hoc,
skipped notarisation, uploaded a 7-day artifact and **finished green with no release published**.

Restored all six. `MACOS_CERT_P12` took three attempts — the first supplied file was a `.cer` (no
private key), the second and third exports were the **Apple Distribution** identity rather than
Developer ID Application. `openssl pkcs12 -nokeys` named the identity in under a second each time,
which is why none of them reached a CI run. A `workflow_dispatch` dry run then proved the whole
pipeline — build, sign, notarise, publish-nothing — before the tag was pushed.

### The full write — measured

38 minutes, `createinstallmedia` 20:29:47 → ~21:07. `.IAPhysicalMedia`, `boot.efi`,
`BaseSystem/BaseSystem.dmg`, `Firmware/`, `Install macOS Tahoe.app` all present, ProductVersion 26.6,
volume renamed `MACINSTALL` → `Install macOS Tahoe`, no orphans. `DiskErase.perform` formatted a real
stick and `call()` held a 38-minute untimed wait — both shipped-today changes proven on hardware.

**Throughput ~8.8 MB/s**, which is the SanDisk stick, not BootIt. The app shells out to Apple's own
binary with no wrapper overhead; Terminal would take the same 38 minutes. `diskutil` calls it
"SanDisk 3.2Gen1" — the interface rating, not the flash speed.

**And the bar was wrong the whole time:**

| Time | `df` used | device I/O |
|---|---|---|
| 20:31 | 1.13 GB | — |
| 20:33 | 2.06 GB | — |
| 20:34 | **18.71 GB** | +16.65 GB in 60 s — impossible at 9 MB/s |
| 20:34 → 21:07 | **18.71 GB, frozen** | steady 535 MB/min |

HFS+ allocates the file up front and the data fills in behind it, so `df` reports the allocation
immediately. Both `used` and `avail` freeze, so neither can drive the bar. Cumulative device I/O
counters tracked the real write accurately for the entire 33 minutes.

### Decisions

- **Shipped without waiting for the full write.** The comparison was not "verified vs unverified" but
  "unverified in one well-tested pure function vs known-broken end to end". The write was run
  afterwards and passed, which validates the call rather than excusing it.
- **Did not fix the progress bar this session.** It needs the I/O-counter source designed properly,
  not a patch bolted on at the end of a session; and it is now the largest remaining UX defect, so it
  leads the queue rather than being squeezed in.
- **Did not run the dry run before the secrets were restored.** Without them it could only exercise
  the ad-hoc fallback — it would not have tested the notarisation path, which was the part in
  question. Run after restoring, it proved exactly the right thing.

### Issues discovered

- **Nothing detects a stale app** whose bundle was replaced underneath it (see above). Cost an hour
  and a false failure report.
- **`currentHelperVersion()` is dead** — one occurrence, the definition. Superseded by the
  fingerprint check; Swift does not warn on unused private methods.
- **The log line still promises "10–20 minutes"** against a measured 38. Folds into the progress fix.
- **`probeWrite` bypasses `decode()`**, so the `HelperFailure.needsFullDiskAccess` → 
  `HelperError.needsFullDiskAccess` mapping is still only unit-tested. It runs for real only on a
  write that fails, which this session's write did not.

### Test results

143 tests, 0 failures. 110 at session start → 143. SwiftLint strict: 0 violations, 34 files.
0 compiler warnings. Receipt committed.

Six mutation checks proved the new tests bite: the `call()` ordering (hangs to timeout), the `defer`
(busy flag stranded), `connectionFailed` without its signal (write parked), `partitionDisk`
scheme/filesystem swapped (3 tests), the Windows scheme flipped to GPT (2 tests), and an unreachable
helper falling through to `.blocked` (3 tests). A seventh caught a dangling colon on an empty error
string before it shipped.

Not covered by tests, verified by hand: the full macOS write, the notarised DMG from the public URL,
the FDA revoke/restore cycle.

### Next session should start with

1. **Copy progress from device I/O counters.** Measured, not theorised — see the table above. Third
   distinct cause of "the bar doesn't move", and the first two are already fixed. Retire the
   "10–20 minutes" line with it.
2. **Stale-app detection + first-run Full Disk Access onboarding.** Likely one piece of work:
   "BootIt was updated while running, quit and reopen" and "BootIt needs Full Disk Access before it
   can write" are the same class of message, both belonging before the user commits to erasing a
   drive. Design call — options range from a launch-time mtime watch to catching the XPC mismatch.
3. **Delete `currentHelperVersion()`**, and decide whether `helperVersion` leaves the XPC protocol
   with it.
4. **Route `probeWrite` through `decode()`**, or accept that the mapping is unit-tested only and say
   so in a comment.
5. **Ask why the release secrets vanished.** Restored, but the cause is unknown, and it silently
   disarmed the release pipeline for an unknown period.

[promote-spine: when a fix spans a client and server that ship inside one bundle, a verification run proves nothing unless BOTH sides are pinned to the same build and that is measured — BootIt spent an hour diagnosing a failure that was a 10:36 app talking to a 10:56 helper across a changed XPC method signature, and the mismatch was only visible by comparing the app's process start time against the bundle's mtime]

[promote-spine: a progress bar driven from filesystem used-bytes measures ALLOCATION, not data — BootIt's ring reached 95% in four minutes and did not move for the remaining 33 of a 38-minute write, while the device took a steady 535 MB/min the whole time; the filesystem reports the allocation up front and both used and avail then freeze, so cumulative device I/O counters are the signal a copy bar has to read]

[promote-spine: a release job whose publish step is gated on `if: <secret> != ''` reports SUCCESS while publishing nothing — BootIt's six signing secrets had been deleted between releases, so a tag would have produced a green run, a 7-day artifact and no release at all; a tag build must fail loud on missing credentials rather than silently degrade to a no-op]

[promote-spine: verify a credential locally before spending a CI run proving it wrong — BootIt's Developer ID .p12 arrived as a .cer with no private key, then twice as the Apple Distribution identity, and `openssl pkcs12 -nokeys` named the wrong identity in under a second each time where the pipeline would have burned a full macOS build to say the same thing less clearly]

[promote-profile:swift: an app that decides what a failure MEANS instead of reporting what it was TOLD gives confident wrong guidance — BootIt asserted "USB access blocked" for a probe that never reached the helper and discarded the daemon's own NSError message in two separate branches, sending the user to change a TCC setting that was never implicated; three instances of one defect in a single session, every one found by reading the screen against the code that produced it]

## 2026-08-03 — Phase 0 ran, and Cancel was still dead

**Commits:** `512575b` → `12f51b1` (6 this session), all pushed.

**CI:** green, SHA-anchored to `12f51b1` (run `30775863931`, `headSha` verified equal to
`git rev-parse HEAD`).
**Local:** receipt `.claude/receipts/bootit-green.build-test-lint.receipt.txt` —
110 tests, 0 failures, 0 SwiftLint violations across 33 files, **0 compiler warnings**.
(98 tests at session start.)

### The headline

The previous session ended with three commits that had restructured the daemon's threading
model and **never been run**. Phase 0 existed to check them before anything was built on
top. It found that the restructuring was fine and that **Cancel had never worked** — for the
second session running, and for a different reason each time.

Measured, not inferred: Cancel pressed twice at 09:33, then `createinstallmedia` wrote for
**forty more minutes** and exited normally at 10:14 having never been signalled. The stick
came out a valid installer. `sudo kill` reported "no such process" because it had already
finished on its own.

### Phase 0 — all three checks answered

| Check | Result |
|---|---|
| One full run to green | **PASS** — `.IAPhysicalMedia`, `boot.efi`, BaseSystem, Firmware all present |
| Cancel mid-copy | **FAIL** → fixed → re-verified: process died, bytes froze at 1.3 GB, no orphan |
| Helper exits ~30 s after the app goes quiet, never mid-write | **PASS** — 31 s, and it correctly stayed up through the whole 40-minute write |

Run order was deliberately inverted from the plan — Cancel first, then the full run — so
that Cancel failed fast, and so the full run afterwards doubled as the test that a cancelled
run released its `ActiveWork` disk claim. In the planned order nothing checked that.

### The cancel bug

`AppModel.cancel()` posted the daemon-facing cancel to `worker` — the **serial** queue that
`runPipeline` occupies for the entire privileged write, blocked inside an untimed
`done.wait()`. The block queued behind the operation it was meant to stop, so the XPC message
never left the app. `"Cancelling…"` appeared because `log()` is synchronous.

The previous session's fix had connected the wiring correctly and connected it to a queue
that was already blocked. Every piece existed, again.

The daemon side was innocent throughout: `cancelCurrentOperation` calls `runner.cancel()`
directly rather than via `workQueue`, and `createInstallMedia` dispatches and returns, so the
delivery queue was free. It was ready to receive a message that never arrived.

Fixed on a dedicated `cancelQueue`, with the daemon-facing call injectable so a test can
occupy `worker` exactly as a write does and prove the message still gets out. Reverting to
`worker.async` fails that test in 2 s while the nothing-is-running case still passes, so it
catches the real condition rather than the existence of a cancel path.

### Cancelling looked like crashing

With Cancel working for the first time, the screen behind it became reachable — and had
never been seen. It reported the user's own choice as a fault: **"Something went wrong"**, a
red banner reading `createinstallmedia failed: createinstallmedia exited 15`, a "What to try"
hint, and a Copy Diagnostics button. Exit 15 is the SIGTERM BootIt itself sent, on request.
The phase checklist called it "Failed".

Now an informational banner, one plain sentence saying the drive is not bootable and to start
over, no diagnostics to send, and the log left collapsed because nothing in it needs reading.
`PhaseState.cancelled` renders a neutral stop mark. Tests assert both directions, so a real
`createinstallmedia` error still gets the red banner and the hint.

### Phase 1 — items 2 and 4

- **Failures now cross XPC as `NSError` codes**, not a `"NEEDS_FULL_DISK_ACCESS: "` prefix the
  app matched and sliced off. Three reviewers had flagged the prefix independently. `@objc`
  cannot carry a Swift enum but `NSError` round-trips natively, so the classification the app
  must act on travels as a code while the text is free to change.
- **The copy poller is a `DispatchSourceTimer`**, not a `while` loop around `Thread.sleep(2)`.
  The loop held a global-pool thread for the entire copy — forty minutes on this stick —
  and could only notice a stop when its current sleep expired.

Not done: item 1 (the `eraseDisk` move) and the rest of item 3 (`call()`, invalidation and
cancel still untested; only the error decode has tests).

### Issues discovered

- **Two dead `catch` blocks around `setCodeSigningRequirement`** (pre-existing; confirmed
  against a stashed tree). The method is non-throwing, so the daemon's block that read
  "reject a connection failing the signing requirement" and the app's
  "the helper failed its signature check" could never execute. The compiler had been warning
  about it. **Security is unchanged** — XPC registers the requirement and invalidates a
  failing connection itself, asynchronously; that is what actually enforces this. A malformed
  requirement string raises an uncatchable ObjC exception, which the catch never covered.
- **A safeguard that guarded nothing.** The `NSError` work first added explicit
  `setClasses` whitelisting on both sides, with a comment asserting XPC does not allow
  `NSError` in a reply by default, and a test asserting the whitelist. The test **passed with
  the whitelisting deleted**. Measured directly: Foundation already infers `NSError` into the
  allowed set from an `NSError?` signature. Safeguard and test both removed.
- **CI was spinning a macOS runner for session-log commits** — three of ten commits in the
  push were docs-only. Now `paths-ignore`; release DMG artifact capped at 7 days.
- **The write is much slower than the UI claims** — ~3.3 MB/s on this stick, so 18.7 GB took
  ~40 minutes against a log line promising "10–20 minutes". Not fixed.

### Decisions

- **Did not gate CI to release events**, which is what the CICOST-P1 finding prescribes. This
  is an Apple Silicon SwiftPM app: build, test and lint cannot run on Linux, so gating would
  remove main's only pre-release signal — and this repo has already shipped a release whose
  main path could not work. `paths-ignore` is the lever that actually exists here. The
  finding stays open and advisory, with the reasoning recorded in the workflow.
- **Corrected the Phase 1 item 1 premise.** Moving `eraseDisk` out of the daemon was framed
  as least privilege. It mostly isn't: `createinstallmedia` erases and reformats the target
  and stays in the daemon, so a compromised daemon keeps its destructive reach. The real
  benefit is de-duplication and testability of two erase paths that differ only in filesystem
  and scheme. Worth doing on those grounds, not on security grounds.
- **Rebuilt and reinstalled before every verification run**, rather than trusting that the
  installed bundle matched HEAD. Last session shipped security fixes that were installed and
  not in effect.

### Test results

110 tests, 0 failures. 98 at session start → 110. SwiftLint strict: 0 violations, 33 files.
0 compiler warnings (2 at session start, both pre-existing).

Three mutation checks proved the new tests bite: reverting the cancel to `worker.async` fails
the blocked-queue test in 2 s; deleting the XPC whitelisting did **not** fail its test, which
is how that safeguard was found to be fictional and removed.

Not covered by tests, verified by hand: the full macOS write, the cancel, the helper's
idle-exit timing.

### Next session should start with

1. **Verify the `NSError` change against a real run.** It rewrote every failure reply across
   the XPC boundary and has only unit tests. Help → Privileged Helper… → **Test USB Access**
   settles the success path in a minute; revoking Full Disk Access and pressing it again
   exercises the error path.
2. **Phase 1 item 3** — `PrivilegedHelper.call()`, invalidation failing an in-flight call, and
   cancel are still untested. Needs a proxy-provider seam. No hardware required.
3. **Phase 1 item 1** — factor the two erase implementations into one tested function in
   `BootItShared`. Decide separately whether it also moves out of the daemon; see Decisions.
4. **First-run Full Disk Access onboarding.** Users still meet the requirement as a failure.
5. **Test whether `SMAppService` registration is admin-gated** — unknown, and it decides
   whether a standard account can approve a system-wide root daemon.
6. **Version bump + tag + notarised release.** GitHub still ships v3.1.0, whose macOS path
   cannot work. This remains the release that matters.

[promote-spine: a cancellation dispatched onto the same serial queue the work occupies can never run — it queues behind the operation it exists to stop, the UI's synchronous "Cancelling…" line appears, and nothing else happens; BootIt shipped this twice, first with nothing calling cancel at all, then with the call posted to the blocked queue]

[promote-spine: a test written alongside a defensive safeguard must be mutation-checked against deleting the safeguard — BootIt added explicit XPC class whitelisting, a comment asserting it was required, and a test asserting it was present; the test passed with the safeguard deleted, because the framework already did it]

[promote-spine: repairing a dead code path makes the UI behind it reachable for the first time, and that screen has never been reviewed by anyone — BootIt's working Cancel immediately revealed a completion screen reporting the user's own choice as a crash, with diagnostics offered for a SIGTERM the app itself had sent]

[promote-spine: when instrumenting a human-driven verification run, size the monitor's lifetime to HUMAN latency (hours), not agent latency (minutes) — a one-hour process monitor expired three hours before the user started the run, and the timeline it existed to capture was lost]

[promote-spine: a CI cost rule of the form "gate the expensive platform build to release events" is wrong for a repo whose only supported platform IS the expensive runner — gating removes the default branch's sole pre-release signal, and the lever that actually exists is paths-ignore for doc-only commits]

[promote-profile:swift: `try` on a non-throwing Objective-C method compiles with only a warning, so a do/catch around `NSXPCConnection.setCodeSigningRequirement` reads as an enforcement check while the catch can never execute — the enforcement is XPC's own asynchronous connection invalidation, and a malformed requirement raises an uncatchable ObjC exception instead]

## 2026-08-02 — the macOS path actually works: privileged helper + the TCC grant

**Commits:** `deb1a76` → `e33d0d3` (7 this session, none pushed).

**Local:** 98 tests, 0 failures; SwiftLint strict 0 violations, 33 files. Signed release
build installed to `/Applications/BootIt.app`.

⚠ **The last three commits are UNVERIFIED against a real run.** `0b79b15` (review fixes)
and `e33d0d3` (fingerprint staleness) changed the daemon's threading model — work moved to
a serial queue, disk claim/release added, idle-exit gated on in-flight work, invalidation
now fails outstanding calls. No write has gone through any of it. **Phase 0 below is the
first thing the next session does.** Two full runs succeeded earlier today, but both
predate this restructuring.

### The headline

**Creating a macOS installer had never once succeeded.** Not in any session. Every run
died at the same point — `createinstallmedia` writing its `.IAPhysicalMedia` cookie to
the root of the target volume, `EPERM`, "The bless of the installer disk failed" — after
fifteen minutes of copying onto a drive that had already been erased. The v3.1.0 release
shipped with a macOS path that could not work.

It works now, verified end to end: blessed system folder, `boot.efi` present, and the
`.IAPhysicalMedia` cookie that failed three times sitting on the drive.

### Root cause — and two wrong diagnoses before it

The cause is **TCC**, not privilege. Writes to a removable volume are gated, and the
process doing the write held no grant. The decisive measurement, which should have been
taken first: the identical write **succeeds from Terminal as an ordinary user** (Terminal
has Full Disk Access) and **fails as root** from BootIt.

- **Wrong diagnosis 1 — responsible-process attribution.** The theory was that TCC blamed
  the GUI app for its `osascript` child, and a system daemon would sidestep it. Built the
  daemon; the failure was byte-for-byte identical. A daemon is subject to TCC too.
- **Wrong diagnosis 2 — the diagnostic itself.** The "which side is blocked" probe filtered
  volumes on `volumeIsInternal == false`, which is also true of a mounted SMB share, so it
  was probing the NAS at `/Volumes/Media` instead of the USB stick.

The actual fix is a **one-time Full Disk Access grant**, which no code can award itself.
The rebuild is what made that grant *possible to hold* — an ad-hoc-signed app run from a
build directory has no stable identity for TCC to attach one to.

### The privileged helper

- LaunchDaemon registered with `SMAppService`, XPC to the app. App and daemon each pin the
  other's code signature (`anchor apple generic` + identifier + team OU) via
  `NSXPCConnection.setCodeSigningRequirement` — the supported macOS 13 API, no private
  `auditToken` access, no PID-reuse race.
- On-demand only: no `RunAtLoad`, no `KeepAlive`, and it **exits 30 s after the app stops
  talking to it**. That exit path was added after a v1 daemon stayed resident across three
  installs and kept serving requests from an old binary.
- Refuses anything that is not a whole external disk, re-checked against `diskutil` rather
  than trusted from the caller.
- Removable from inside the app: **Help → Privileged Helper…**, which also has
  **Test USB Access** — runs the exact failing syscall from both the app and the daemon and
  reports which one is refused.
- **Probes before erasing.** A missing grant now costs a message, not the drive's contents.

### The progress bar: measured, not parsed

`createinstallmedia` on macOS 26 emits percentages for the **erase only**. The entire
copy — the multi-gigabyte, fifteen-minute part — prints three lines and no numbers:

    Erasing disk: 0%... 10%... 20%... 30%... 100%
    Copying essential files...
    Copying the macOS RecoveryOS...
    Making disk bootable...

Older macOS printed `Copying to disk: 0%...100%`, which is what the mapping assumed. So
no amount of output parsing could move that bar — the information is not in the output.
The daemon now polls the target volume's used bytes (`statfs`, every 2 s) and maps that
onto 15% -> 93%, following the **device** rather than the path, because the volume is
renamed from `MACINSTALL` to `Install macOS Tahoe` partway through. Payload size is
estimated from `SharedSupport.dmg` x 1.2; the bar is capped at 93% so only the completion
line finishes it, since an estimate that runs short would otherwise sit at 100% for
minutes — the same "is it stuck?" failure in a different costume.

`lastFraction` is now written by both the output reader and the poller, so
compare-and-advance is a single locked step.

### Bugs a real run exposed

- **Progress froze at 50% for an entire 20-minute write.** The daemon held its callback
  proxy in a `weak var`; `remoteObjectProxy` is autoreleased, so it was nil before the first
  callback and every log line and progress update went nowhere. No error anywhere.
- **The percent parser read the first match on a line.** `createinstallmedia` rewrites one
  line in place — `Erasing disk: 0%... 10%... 20%` — so it reported 0 forever. The old code
  had `lastPercent` for exactly this; the rewrite deleted it.
- **Reusing a local installer parked the bar at 50%** before any work started.
- **A skipped download was ticked green**, so a ring at 2% looked like it had reset. Now a
  distinct `.skipped` state, which also survives `state(of:)`'s short-circuit to `.done`.
- **"Quit" was the completion step's primary button**, bound to `.defaultAction`, while the
  drive it had just written was still mounted — Return was one keystroke from an unejected
  pull. Eject is primary now, becoming Done once safe.
- **Closing the window stranded a running, windowless app** (New Window is removed). This
  was carried as "deferred" from the previous session and was the reason Quit existed.
- `/Volumes/Shared Support` was only unmounted on success — never on the path that
  abandoned it. Now in a `defer`.

### Decisions

- **Daemon + manual FDA, not an app-spawned root child.** macOS *can* auto-prompt an app for
  removable-volume access, which might mean zero manual steps — but it costs a password
  prompt every run, attributed to "osascript". Rejected: the one-time grant is what disk
  utilities do, and Mick had objected to the osascript attribution twice.
- **Progress split stays 50/50** between download and write, and the write takes the full
  ring when the installer is already on disk. Confirmed as wanted. Known imprecision: the
  split is fixed, not weighted by measured throughput.
- **Skipped `/tri-model`** — the decision failed the "genuinely open" test. Apple documents
  `SMAppService` and Mist solves the identical problem the same way.

### What to watch for next time

The pattern across both wrong diagnoses: **reasoning ahead of the measurement**. Both the
app and the daemon fail with an identical `EPERM` while being governed by entirely separate
TCC rules, so the symptom carries no information about the cause. The `Test USB Access`
button exists so that is never guessed at again.

### Independent review — what two fresh-context reviewers found

Run at the end of the session, on the author's instruction ("I don't want this to be a
vibe-coded lines-on-top-of-lines job"). They were right to be asked.

- **Cancel was dead code.** The XPC method, `ToolRunner.cancel()` and
  `PrivilegedHelper.cancel()` all existed; nothing called the last one. The button did
  nothing for up to twenty minutes. Every piece present is exactly why it read as done.
- **`volumeName` had no validation** while `disk` had a regex, an external-disk re-check
  and its own test class — and `volumeName` was interpolated into `/Volumes/<name>` and
  handed to a root `createinstallmedia`. `".."` resolves to `/`.
- **Root-exec of a caller-supplied path** behind nothing but an is-executable check.
- **Idle-exit could orphan a live child.** `exit()` does not kill `createinstallmedia`; it
  reparents to launchd and keeps writing, and the next launch starts a second write on the
  same drive.
- **`invalidate()` never failed an in-flight call**, so Remove Helper mid-write hung the
  write thread on its semaphore forever.
- **No mutual exclusion** on destructive operations; **XPC methods blocked their own
  connection**, so a cancel could not have been delivered even once wired.

All fixed in `0b79b15`. Then, immediately after: the version constant had **not** been
bumped, so the app kept talking to a resident daemon running the pre-fix binary — the
fixes were installed and not in effect. Fixed properly in `e33d0d3` by fingerprinting the
running binary instead of trusting a constant.

### Next session — the plan

**Phase 0 — verify before touching anything.** The daemon's threading model changed at the
end of a long session and no write has exercised it.
  1. One full run to green.
  2. **Cancel mid-copy** — never fired once. Must stop in seconds with a clean failure, not
     a hang. Use a throwaway drive.
  3. `pgrep BootItHelper` after: gone ~30 s after the app goes quiet, and never mid-write.
  If Cancel fails, everything below waits.

**Phase 1 — the real cleanup** (fresh context; this is restructuring, not patching):
  1. **Move `eraseDisk` out of the daemon.** It never needed root — it ran unprivileged
     before this session and `USBWriter.erase()` still does, unprivileged, in the same
     binary. It was folded in because a daemon was already being built, and it duplicates
     USBWriter's erase-retry line for line. Factor one tested function into `BootItShared`.
  2. **Replace the `NEEDS_FULL_DISK_ACCESS:` string prefix with an `NSError`.** `@objc`
     can't carry a Swift enum but `NSError` round-trips over XPC natively. Three reviewers
     flagged it independently.
  3. **Tests for `PrivilegedHelper` itself.** The riskiest file has none — `call()`,
     invalidation, cancel, the error decode. Inject a proxy provider and mock the protocol.
  4. `DispatchSourceTimer` instead of `Thread.sleep` in the copy poller.

**Phase 2 — release readiness:**
  1. **Test whether `SMAppService` registration is admin-gated.** Unknown, and it decides
     whether a standard account can approve a system-wide root daemon. 5 min on a test
     account.
  2. **First-run Full Disk Access onboarding** — users meet it as a failure today.
  3. **CI cost fix** — `ci.yml:14` runs macOS (~10× Linux) on every push with no `if:`.
     Do this BEFORE pushing seven commits.
  4. **Version bump + tag + notarised release.** GitHub still ships v3.1.0, whose macOS
     path cannot work. This is the release that matters.

[promote-spine: when a privileged operation fails with EPERM as root but succeeds as an ordinary user, it is TCC, not permissions — and root daemons are NOT exempt; they simply can never be prompted, so the grant has to be made by hand]

[promote-spine: an autoreleased XPC remoteObjectProxy stored in a `weak var` is nil before the first callback — the channel goes silent with no error at all, which reads as "the work is stuck" rather than "the callbacks are gone"]

[promote-profile:swift: a launchd daemon with no idle-exit stays resident across app updates and keeps answering from the old binary — an on-demand SMAppService helper should exit when idle or a stale build will serve requests indefinitely]

[promote-spine: a CLI's progress output is a version-dependent contract — macOS 26's createinstallmedia prints percentages for the erase and nothing for the 15-minute copy, where older versions printed "Copying to disk: x%"; when the numbers aren't in the output, measure the effect (bytes landing on the volume) instead of parsing harder]

[promote-spine: `volumeIsInternal == false` is true of mounted SMB/AFP shares as well as USB sticks — a "find the external volume" filter needs volumeIsLocal too, or diagnostics silently describe the wrong device]

[promote-spine: a subsystem where every piece exists reads as finished — BootIt's cancel had an XPC method, a ToolRunner.cancel() and a PrivilegedHelper.cancel(), and nothing ever called the last one; grep for the call site, do not infer completeness from the parts]

[promote-spine: harden one caller-supplied parameter and you will forget its neighbour — BootIt validated `disk` with a regex, an external-disk re-check and a dedicated test class while `volumeName` beside it went unvalidated into a root process's path; validate the whole argument list of a privileged call, as a set]

[promote-profile:swift: a privileged helper's staleness must be detected by fingerprinting the binary the daemon actually launched with, never by a hand-bumped version constant — the constant was missed twice, once shipping security fixes that were installed but not in effect]

[promote-spine: never bind a destructive-adjacent "Quit"/"Done" to .defaultAction on a completion screen while removable media is still mounted — Return becomes one keystroke from an unejected pull]

## 2026-07-31 → 2026-08-01 — v3.1.0 release, UI redesign, macOS-path fixes

**Commit:** `4085ff0` — "Reuse an installer already on disk, and close the assistant that opens itself"
(9 commits this session, `9f0d078` → `4085ff0`)

**CI:** green, SHA-anchored to `4085ff0` (run `30696081083`, `headSha` verified equal to `git rev-parse HEAD`).
**Local:** `swift build -c release --arch arm64 && swift test && swiftlint lint --strict` → receipt
`.claude/receipts/bootit-green.build-test-lint.receipt.txt` (63 tests, 0 failures, 0 lint violations).

### Completed

**Release + distribution**
- **v3.1.0 shipped** — signed with Developer ID, notarised, stapled. `spctl` reports
  `accepted — source=Notarized Developer ID` for both the `.app` and the DMG, so the
  Open Anyway step is gone for downloaders.
- `mac/build.sh` takes `BOOTIT_SIGN_ID` → hardened runtime + secure timestamp; new
  `mac/package.sh` builds the DMG and drives notarytool.
- `.github/workflows/release.yml` — tag `v*` builds, signs, notarises and publishes.
  Ran green on its first real execution. Publishes **only** when signing secrets exist,
  so it can never push an unsigned DMG over a notarised one.
- Notarisation authenticates with the existing App Store Connect API key
  (`~/.config/asc-mcp/AuthKey_7CANPHUN78.p8`), keychain profile `bootit-notary` — no
  app-specific password anywhere.
- **Intel dropped.** Homebrew no longer publishes an x86_64 `wimlib` bottle; Intel Macs
  already have Boot Camp Assistant, which is the gap this app fills on Apple Silicon.
  `package.sh` refuses to build a DMG unless every Mach-O is arm64.
- History rewritten to `LEME Digital <8488454+iwannabesurfing@users.noreply.github.com>`,
  Claude co-author trailers stripped, `v3.0.0` tag re-pointed. Contributors now reads
  `iwannabesurfing` alone.
- `leme.com.au/bootit/` corrected (leme-web `9d906fc`) — it still claimed Intel support
  and an unsigned app.

**UI**
- Flow logic extracted from `ContentView` into `Flow.swift` as derived state plus a
  `FlowDecision` value; filesystem check injected. The view layer had no coverage at all
  because the riskiest logic was unreachable from a test.
- `ContentView` (601 lines) split into `RootView` + 6 step views + 5 components + tokens.
- Native toolbar, route-aware step indicator, 620pt content column, Help menu.
- Progress rebuilt: `WritePhase` checklist driven by observational callbacks from the
  writers (additive, default no-op — write logic untouched), determinate ring, log
  collapsed by default and auto-opening on failure.
- 29 preview fixtures behind `#if DEBUG`, verified absent from the release binary.

**Safety**
- Drive selection: Picker → cards showing name, capacity and BSD id. **Nothing is
  preselected.** Rescan tracks the drive by id, not index, so an unplugged drive clears
  the selection instead of sliding it onto a different disk. `start()` guards on a live
  selection, removing an out-of-range crash `disks[diskIndex]` could hit.
- System confirmation with a destructive role before any erase; Return no longer reaches
  an irreversible operation directly.

### Issues discovered and fixed this session

- **`diskutil -69850` on erase** — characteristic of a drive already carrying a bootable
  layout. `eraseDisk` reuses the existing scheme, so retrying could never work. Both
  writers now fall back to `partitionDisk`. Found by a real run, not by tests.
- **~18 GB re-downloaded needlessly** — `softwareupdate --fetch-full-installer` ran
  unconditionally even with the exact installer already in `/Applications`. Now matched on
  `DTPlatformVersion` (the OS delivered), **not** `CFBundleShortVersionString` (the
  installer app's own version).
- **The macOS installer assistant launched itself** and had mounted the Mac's own system
  volume as an install target (`/Volumes/msu-target-*` → `disk3s3` "Macintosh HD"). A user
  clicking Continue on a window they didn't open would have been upgrading their Mac.
  BootIt now closes it after download and again before `createinstallmedia`.
- **`bytesHuman` divided by 1024 while labelling the result GB** — a 61.5 GB stick read as
  57.3 GB, disagreeing with Disk Utility and its own packaging on the one screen that
  exists to confirm which drive gets destroyed. Now base-1000, matching macOS since 10.6.
- Four presentation defects visible only in a running app: failed phase rendered as
  "in progress"; footer left a dead disabled Cancel after failure; two different
  percentages on one line; toolbar icon read as a hamburger and duplicated a labelled
  control.
- Latent: version tiles were a non-wrapping `HStack` that would squash as Apple's list
  grows → `LazyVGrid`.

### Decisions made

- **Apple Silicon only**, rather than an Intel CI leg or building wimlib from source.
  Rationale recorded in the README so it isn't "fixed" later.
- **Stay SwiftPM-only; no XCUITest.** SwiftPM supports no UI-test target, and adding an
  Xcode project to get one would mean maintaining two build systems beside `build.sh` and
  CI. Coverage comes from extracting logic out of View bodies instead.
- **No snapshot tests** — they would render differently on this Mac than on the `macos-15`
  runner and go flaky immediately.
- **Windows logo not used.** Microsoft's own guidance: logos "can never be used without an
  express license", while truthful reference by name is permitted. SF Symbols + the word
  mark instead.
- **`osascript` attribution left as-is.** Making the admin prompt say "BootIt" needs a
  privileged helper (SMJobBless) — disproportionate. The UI and log now explain the prompt.
- **"Quit" → "Done" deferred**, not skipped: `BootItApp` removes the New Window command, so
  dismissing the last window would strand the user with a running, windowless app. Needs
  terminate-on-last-window-close handling first.
- `.gitignore` narrowed from `.claude/` to `.claude/*` with negations — the session log,
  promotion queue and receipts are the record of what happened, not local settings.

### Test results

63 tests, 0 failures. 14 at session start → 63. SwiftLint strict: 0 violations, 26 files.
Two mutation checks proved the suite bites: preselecting a drive, and bypassing the
confirmation dialog, each fail their test.

Not covered by tests, verified by hand: VoiceOver, keyboard-only operation, dark mode.

### Next session should start with

1. **Retry the macOS path end-to-end** — reuse + assistant-close + `partitionDisk` fallback
   are all unverified against a real run. Reboot first: `/Volumes/Shared Support` and
   `/Volumes/msu-target-*` were left mounted by the assistant.
2. **Confirm Xcode renders the previews.** `#Preview` compiles at the macOS 13 target, but
   whether Xcode previews a SwiftPM *executable* target is unresolved. If not, the fix is a
   library target with a thin executable — a `Package.swift` change.
3. **Ship the redesign.** v3.1.0 on GitHub is the *old* UI; none of this session's UI work
   is released. Needs a version bump + tag.
4. Optional: add the 6 repo secrets so tagging publishes without a local build.
5. Optional: dark mode and VoiceOver passes.

[promote-profile:swift: SwiftPM supports no XCUITest target — view-layer coverage on an SPM app comes from extracting navigation/enablement logic out of View bodies into testable value-returning functions, not from adding UI tests]

[promote-spine: a vendor's logo needs an express licence even when you legitimately integrate with them — Microsoft's guidance says logos "can never be used without an express license" while truthful reference by name is permitted; check the vendor's own trademark page before shipping their mark]

[promote-spine: agent-built UI needs one real screenshot round before it is called done — four presentation defects survived 52 green tests and a clean build, and were visible the moment a human ran the app]
