# BootIt — session log

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
