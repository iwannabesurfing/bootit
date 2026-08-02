# BootIt — session log

## 2026-08-02 — the macOS path actually works: privileged helper + the TCC grant

**Commits:** `deb1a76` "Run createinstallmedia from a privileged helper, and make the
macOS path work", `5c456c6` "Say Skipped when no download happened".

**Local:** 81 tests, 0 failures; SwiftLint strict 0 violations, 33 files. Signed release
build installed to `/Applications/BootIt.app`.

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

### Next session should start with

1. **Confirm the progress ring live** — the callback fix is proven (2% → 5% and daemon log
   lines now reach the UI), but no completed run has yet exercised the copy phase climbing
   15% → 100%.
2. **Version bump + tag.** GitHub still has v3.1.0, whose macOS path cannot work. This
   release matters more than the UI redesign did.
3. **First-run FDA guidance.** The grant is documented and detected, but a new user still
   meets it as a failure rather than as onboarding.
4. Add the 6 repo secrets so tagging publishes without a local build.

[promote-spine: when a privileged operation fails with EPERM as root but succeeds as an ordinary user, it is TCC, not permissions — and root daemons are NOT exempt; they simply can never be prompted, so the grant has to be made by hand]

[promote-spine: an autoreleased XPC remoteObjectProxy stored in a `weak var` is nil before the first callback — the channel goes silent with no error at all, which reads as "the work is stuck" rather than "the callbacks are gone"]

[promote-profile:swift: a launchd daemon with no idle-exit stays resident across app updates and keeps answering from the old binary — an on-demand SMAppService helper should exit when idle or a stale build will serve requests indefinitely]

[promote-spine: `volumeIsInternal == false` is true of mounted SMB/AFP shares as well as USB sticks — a "find the external volume" filter needs volumeIsLocal too, or diagnostics silently describe the wrong device]

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
