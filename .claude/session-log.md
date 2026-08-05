# BootIt — session log

## 2026-08-05 (session 2, part 3) — cancel fired for the first time, and mostly passed

**Commit:** `b127528`. **Tag:** `v3.4.1`, published and verified from `releases/latest`.

**CI:** green, SHA-anchored to `b127528` (run `30979752062`, all eight steps, none skipped). **Release:**
run `30979867390`, all twelve steps green.
**Local:** receipt — **254 tests** (248 at part 2), 0 failures, 0 SwiftLint violations across 48 files,
0 compiler warnings from a cleaned tree, TSAN-clean, design-index green, **17 mutations all biting**.

### Cancel works. It has never been run until today.

On the Phase 0 list since 2026-08-03, deferred four sessions because it needs a real drive and
destroys whatever is on it. Fired mid-copy on the notarised v3.4.0 build, 85 s into a ~30 min write:

```
15:37:18.9  createinstallmedia starts (pid 95128)
15:37:35.0  enters state U — the copy proper
   …        writes steadily, 153 MB → 1.145 GB
15:38:44.1  gone. no orphan, none thereafter
```

| Property | Result |
|---|---|
| The write actually stops | ✅ 85 s of a ~30 min job |
| No orphaned child reparented to launchd | ✅ never reappeared |
| Trace ends clean at 84.5 s | ✅ no truncation, no error spew |
| Drive left mounted and sane | ✅ 1.17 GB of a partial installer |
| Reported as **cancelled**, not failed | ✅ info banner, neutral phase marker, log stayed collapsed |

So `0b79b15` — moving the cancel off `worker`, the queue the privileged call was itself blocking —
**is correct in the real case it was written for**, confirmed rather than assumed.

### What it got wrong is the part between the click and the stop

`cancel()` set the flag, wrote `"Cancelling…"` to a log that is **collapsed by default**, and touched
nothing else. So for the whole window the screen still read *"Copying macOS to the drive…"* with the
byte counter **climbing** — measured 1.00 → 1.145 GB *after* the click, because SIGTERM cannot be
delivered to a process in uninterruptible sleep until it surfaces. `createinstallmedia` surfaced from
`U` to `R` **twice in 85 seconds**.

Every number on that screen was true, and the screen was false. The only available reading is that
the button did nothing.

This is synthesis **UNANIMOUS #9**, decided at the 2026-08-03 gate and never built:

> Cancel must tell the truth during uninterruptible sleep … the UI must say "waiting for the drive to
> respond" rather than appear to ignore the click.

Built now: an `isCancelling` window distinct from the `wasCancelled` outcome; the status line taken
over by "Cancelling — waiting for the drive to respond…"; the liveness line suppressed, because two
true statements that contradict each other are resolved by the user in favour of the wrong one; and
the button relabelled `Cancelling…` and disabled, since a second press can only confirm that pressing
it does nothing. Cleared in `endCopyReporting()`, the one defer that runs however a run ends —
including the write finishing normally in the seconds after the click.

Three mutations, all biting: status line untouched, liveness line surviving, button staying live.

### Decisions

- **Suppress the liveness line rather than caveat it.** It is the one place BootIt deliberately hides
  a true, measured number. Justified because the contradiction is what misleads, not the number.
- **Folded into v3.4.1 rather than deferred.** A release was being cut for the 95% fix anyway, and
  shipping a cancel that looks broken while knowing why would be a choice.
- **`isCancelling` is separate from `wasCancelled`.** Window versus outcome; collapsing them would
  make "cancelled" unrenderable while the cancel was still pending.

### Not done

- **The pty probe.** Unchanged from part 2 — the copy percentages exist and arrive block-buffered;
  that reopens the synthesis's core decision and wants its own session.
- **Cancel latency was not measured from the click.** The watcher timestamps the process, not the
  press, so "how many seconds did the user stare at it" is still unquantified. The fix makes the
  window legible rather than shorter, and that is the honest claim.

[promote-spine: a cancel that cannot be delivered immediately needs a state of its own — SIGTERM to a process in uninterruptible sleep waits for it to surface (measured: twice in 85 seconds), so between the click and the stop the UI must name the wait, disable the control, and stop showing counters that keep rising, or the only available reading is that the button did nothing]

[promote-spine: two true numbers can make a false screen — BootIt showed "waiting for the drive to respond" over a byte counter that was still climbing, and both were accurate; when a measured value contradicts a state, suppress the value rather than caveat it, because the user resolves the contradiction in favour of the wrong one]

[promote-spine: a decision recorded as UNANIMOUS in a design gate is not thereby implemented — BootIt's synthesis agreed cancel must report the uninterruptible-sleep wait, and the code shipped without it for two sessions because the gate's output was a document and nothing checked the document against the build]

## 2026-08-05 (session 2, part 2) — the hardware run, and the question that found the bug

**Commits:** `a5bd14a`. **Tests:** 248 (241 at part 1), **14 mutations, all biting** (11 + 3 new).

### The headline

v3.4.0 was verified end to end on hardware — a full 30-minute macOS write, notarised build from
`/Applications`, helper approved and running as root. **The release works.**

It also produced the first user-visible defect this project has found by *watching* rather than
testing, and the finding is not the defect. It is that **three separate pieces of the codebase
asserted, as fact, something two committed traces already contradicted.**

The user asked: *"if it's making the drive bootable, why is it still copying?"*

### What was wrong

`createinstallmedia` prints `Making disk bootable...` at **17.9%** (2026-08-04) and **14.7%**
(2026-08-05) of the run. Three places treated it as the end:

| Where | Claim | Effect |
|---|---|---|
| `InstallMediaProgress:59` | `return 0.95` — "emitted right at the end" | ring showed **95% for 25.6 of 30 minutes** |
| `CopyProgressModel.announcesFinishing` | matched that line, flag is sticky | status read "Making the drive bootable…" for **85% of the run** |
| `BootItHelper/main.swift:334` | "the only trustworthy signal that the bulk copy is over" | comment only — but it is the belief the other two were built on |

At the moment the ring said 95%, the device had written **2.85 GB of 21.26 GB — 13.4%**.

### The number came from misreading a ceiling as a value

The synthesis records Gemini's guardrail as **"clamp to 95%"** — a *ceiling* on a determinate bar,
adopted under UNANIMOUS #7 ("never reach 100% before the process exits"). It was implemented as a
*value*, on the phase §3.2 of the same document requires to be "animated, not a frozen number".

So this was not a decision that aged badly. It contradicted the synthesis on the day it was written.
Deleting it **restores** the adopted design; nothing here overrides a gated decision.

### The premise under the whole feature is false

The trace's last stage line:

```
{"elapsed":1646.6,"line":"Copying to disk: 0%... 10%... ... 100%"}
```

`InstallMediaProgress` said, twice, that macOS 26 emits nothing during the copy. **It emits this**,
and it has been sitting in `copy-run-2026-08-04.jsonl` since the day that fixture was committed —
in the same session the claim was written. `RecordedRunTests` even *quotes the line* in a test
docstring while the source file three directories away denied it existed.

Why it looked like silence: the three middle banners arrive **0.2 ms apart**. Sequential stages
cannot be simultaneous, so `createinstallmedia`'s stdout is **block-buffered because it is a pipe
rather than a tty**, and every percentage is inside one line by the time we see it, at ~90%.
BootIt's reader is not at fault — it already splits on `\r` and `\n` (`main.swift:73`).

**Not acted on.** Defeating the buffering with a pty is the open question this reopens, and it
would revisit the synthesis's core decision rather than restore it. Flagged, not attempted.

### Fixing it correctly required a second fix

Nulling the fraction alone would have replaced an over-claim with an under-claim: `CopyRing.value`
returned `progress` for `.finishing`, and `progress` still holds the erase ceiling through the copy,
so the ring would have drawn **~15% at 90% through**. It survived before only because the 0.95 fed
it at the same instant. `.finishing` no longer draws a number either — §3.2 and #8, no exemptions.

### The test that should have caught it had an exemption for it

```swift
let opaque = states.filter {
    if case .finishing = $0.activity { return false }   // ← removed
    return true
}
XCTAssertTrue(opaque.allSatisfy { $0.fraction == nil })
```

The one state that claimed a percentage was the one state the test agreed not to look at. Two more
of the same shape: `testRealTahoeTranscriptNeverGoesBackwards` held a "verbatim" transcript with the
counter-example line **missing**, and `testAFilesystemDrivenBarWouldShow99PercentAOneFifthOfTheWay`
pins `df` reaching 99% at **310 s** while the banner lands at **309.1 s** — the same instant, two
instruments, one condemned in a test and the other shipped in the UI.

### What was added

- `copy-run-2026-08-05.jsonl` — 907 samples, 30.0 min, the second complete trace.
- `EveryRecordedRunTests` — properties held against **every** committed trace, so adding trace #3 is
  the act of testing the claims rather than filing them. Four tests, including the buffering one.
- Three mutations, all biting: restoring the 0.95, restoring the banner as the finishing signal, and
  restoring the determinate tail ring.

### Decisions

- **`announcesFinishing` now matches `Copying to disk` + `100%`** — 90.4% and 91.4% across the two
  traces. Matching the completed percentage matters: the line is `\r`-rewritten, so a partial read is
  a legitimate earlier view of it. **n = 2, one device** — said so at the call site, and named the
  assertion to break first if a third trace disagrees.
- **The pty question is deferred, not skipped.** It changes what the synthesis decided, not how it
  was implemented.
- **The design-index row now carries the falsified premise inline**, so the next session meets it
  before the synthesis rather than after.

### Not done

- **Cancel has still never been fired.** Four sessions on the list. It needs the drive, and the drive
  is now a good installer.
- The pty probe. One more 30-minute run would settle it.

The "a comment claiming what a tool does, refuted by a fixture committed beside it" lesson was
**folded into the existing `an-inference-recorded-as-observation-becomes-fact`** as its third
instance rather than filed separately — it is the same defect class, and that candidate is the one a
reader would already reach. Five new candidates plus that section, against a federation queue at 276
pending on a 221 ceiling; the cluster is real but the budget is a cost worth naming.

[promote-spine: a stage banner is printed when a stage BEGINS, so it can never mean "nearly done" — `createinstallmedia` prints "Making disk bootable" at 15% of the run with 87% of the bytes outstanding; timestamp a banner against the bytes that followed it before letting it drive a bar]

[promote-spine: when a test filters out a state before asserting a property, ask whether that state is the one that violates it — BootIt exempted `.finishing` from "the ring never claims a percentage", and `.finishing` was the only state that claimed one]

[promote-spine: a guardrail expressed as a CEILING ("clamp to 95%") gets implemented as a VALUE — the synthesis said never exceed 95% before exit, the code returned exactly 0.95 on the phase the same document said must show no number; when transcribing a bound into code, name it as a bound]

[promote-profile:swift: a child process's stdout is block-buffered when it is a pipe rather than a tty, so `\r`-rewritten progress arrives in one batch at the end and reads as silence — three sequential stage banners landing 0.2 ms apart is the signature; the fix is a pty, not a better parser]

[promote-spine: removing a bad mechanism does not remove the belief that produced it — BootIt deleted a used-bytes denominator that froze at 95%, and left a hand-written 0.95 firing on the same event, from the same false premise, one file away]

## 2026-08-05 (session 2) — v3.4.0 shipped, and the account nobody needed to create

**Commits:** `031b7fc` (bump) → `c98933c` (this log entry), both pushed. Tag `v3.4.0` pushed.

**CI:** green, SHA-anchored to `031b7fc` — run `30959694084`, all eight steps ran, **none skipped**,
`headSha` verified equal to `git rev-parse HEAD` at the moment of tagging. The log commit is
docs-only, so path filtering runs Design index alone on it: run `30961618125`, green, `headSha`
`c98933c`. That is the CI-cost gating working as intended, not a skipped check — no Swift source
changed after `031b7fc`.
**Release:** run `30961284215` — all twelve steps green, including the tag↔`Info.plist` check,
the Developer ID import and notarisation.
**Local:** receipt `.claude/receipts/bootit-green.build-test-lint.receipt.txt` — **241 tests, 0
failures**, 0 SwiftLint violations across 48 files, 0 compiler warnings from a cleaned tree with
`-Xswiftc -warnings-as-errors`, full suite ThreadSanitizer-clean, design-index lint green,
mutation-harness self-test green (seven checks, seven distinct reasons).

### The headline

The previous session left **nothing carried** and named the release as the one thing with outside
consequences. That is what this session did. No compiled source changed — the only edits are
version strings, a README example and one prose line.

**v3.4.0 is live**, signed, notarised and stapled. It is the first release carrying the
administrator warning, the `BootItKit` restructure and the off-main-thread bundle read; GitHub had
been shipping v3.3.0, which predates all three.

### The release was verified from the URL a user actually hits

A green publish job is not a published artefact — this repo already carries
`publish-gated-on-a-secret-succeeds-silently` in the queue for that exact failure. So the check was
made against `releases/latest/download/BootIt.dmg`, the durable URL `leme.com.au/bootit/` points at,
not against the workflow's own artifact:

| Check | Result |
|---|---|
| DMG through Gatekeeper | `accepted — source=Notarized Developer ID`, LEME Digital (MD4M4DL5PP) |
| `.app` inside it | `accepted — source=Notarized Developer ID` |
| `stapler validate` | worked — the ticket is stapled, so it opens offline |
| `CFBundleShortVersionString` | `3.4.0` |
| Architecture / helper | arm64, `BootItHelper` embedded |

The bundle was also assembled locally before the tag went up, because `mac/Info.plist` is read by
`build.sh` and **not** by `swift build` — so the version bump is invisible to the entire test suite.
Checked against the binary's own timestamp (5 s old), since a stale `dist/` answers just as
confidently. Release binary: **zero** preview symbols.

### The one open question narrowed itself, for free

Carried as "if it is ever worth an account": does a standard user get an authentication sheet on the
Login Items switch, or is it simply unavailable? Last session's own lesson says to ask whether a
primary source answers a human-gated question first. One does — on this machine:

```
com.apple.ServiceManagement.daemons.modify   →  k-of-n 1 of
  is-root
  entitled-admin-or-authenticate-admin-nonshared  →  k-of-n 1 of
      entitled-admin-nonshared
      authenticate-admin-nonshared   →  class: user, group: admin,
                                        authenticate-user: true, shared: false
```

`authenticate-user: true` with `group: admin` is the shape that **presents a sheet and accepts any
administrator's credentials** — it does not require the session's owner to be one. Corroborating:
`LoginItems.appex` links `SFAuthorization` and carries `performForWindowID:withAuthorization:`,
which is a UI built to run an action behind a sheet, not one that greys a switch out.

**This did not close the question and the copy was not changed.** Neither reading names the
daemon-approval toggle specifically: the right proves what ServiceManagement requires, the appex
proves the pane *can* raise a sheet, and "System Settings routes this switch through that right" is
inference. Shipping *"an administrator can approve it here, now"* on an inference fails in the
confident direction. The existing wording is merely pessimistic, which is the safe one.

What changed is the **cost of closing it**: someone with a standard account now observes one thing —
sheet or no sheet — instead of exploring.

### Decisions

- **Minor bump, 3.4.0, not 3.3.1.** The administrator warning is a new user-facing surface, not a
  fix to an existing one.
- **Published directly, not as a draft.** All six repo secrets are present, the previous two
  releases went the same way, and a draft would add a manual step to a path that has been green
  three times running.
- **The auth-database reading was recorded, not acted on** — see above.
- **`docs/DESIGN-INDEX.md`'s honest-gaps line moved to v3.4.0.** It states which version reached
  this state with six undocumented subsystems; leaving it at v3.3.0 would date the claim rather
  than the gap.

### Test results

241 tests, 0 failures — unchanged from session start, and that is the point: no compiled source was
touched. SwiftLint strict 0 violations across 48 files. TSAN-clean. Mutation-harness self-test green.
The eleven-mutation corpus was **not** re-run, deliberately: every anchor was re-verified last
session after the restructure that moved them, and nothing has moved since.

### Next session should start with

1. **Nothing carried.** The release is out and verified, the queue validates clean, the design index
   is current.
2. **The auth-sheet question, now one observation wide** — log in as a standard user, open Login
   Items, and look. If a sheet appears, the warning copy improves from "someone who administers this
   Mac has to approve it" to "an administrator can approve it here, now". Not a blocker.
3. **A real end-to-end run on v3.4.0 hardware.** The macOS path has not been exercised against a
   notarised build since the restructure — the code is unchanged and CI is green, but the helper
   registration path is the one thing only a signed build from `/Applications` can prove.
4. **`AppModel`'s pipeline is still untested as sequencing** — recorded three sessions ago as a
   deliberate skip with reasoning. The trigger should be a bug in the sequencing, not a line count.

[promote-profile:swift: "will macOS let a non-admin do this?" is usually answerable without a second account — `security authorizationdb read <right>` resolves the rule chain, and `class: user` + `group: admin` + `authenticate-user: true` means a sheet is presented that ANY administrator can satisfy in someone else's session, while a rule with no authenticate leg is decided by who is logged in and no sheet helps]

No second candidate was filed for "verify the release from its public URL" — the queue already
carries `publish-gated-on-a-secret-succeeds-silently`, whose advice this session followed rather
than rediscovered. That candidate gained a section recording the check being applied and passing.
The federation queue is 276 pending against a 221 ceiling; a near-duplicate is a cost, not a
capture.

[promote-spine: a version string that only a packaging script reads is invisible to the entire test suite — bumping it changes nothing any test can see, so assemble the artefact and read the version back out of it before tagging]

## 2026-08-05 — both stale questions closed, and the fix for one was wrong

**Commits:** `e4bddad` → `16af11c` (3 this session), all pushed.

**CI:** green, SHA-anchored to `16af11c` (`headSha` verified equal to `git rev-parse HEAD`). Both
workflows green on the final tree: run `30957737266` (CI — all eight steps ran, **none skipped**,
including the mutation-harness self-test that failed on the first push) and run `30957737118`
(Design index). The first push, `0cec37c`, went **red** — see below; that is the honest anchor for
what this session shipped before it was fixed.
**Local:** receipt `.claude/receipts/bootit-green.build-test-lint.receipt.txt` — **241 tests, 0
failures** (233 at session start), 0 SwiftLint violations across 48 files, **0 compiler warnings**,
full suite ThreadSanitizer-clean, design-index lint green. From `swift package clean`, with
`-Xswiftc -warnings-as-errors`. **All 11 mutations re-run and all 11 bite**, after a refactor that
moved every one of their anchors.

### The headline

The two items that had fallen off the record for four sessions were both closed. Neither closed the
way it was written down.

- **"Is `SMAppService` registration admin-gated? ~5 min on a test account."** It needed no test
  account. Apple states the rule in `SMAppService.h`, on disk in the SDK.
- **"Does Xcode render `#Preview` for a SwiftPM executable target?"** It needed a human, briefly —
  but **the fix queued alongside it was wrong**, and that was falsifiable for free.

### Registration was never the gate

From `SMAppService.h`, the discussion for `registerAndReturnError`:

> If the service corresponds to a LaunchDaemon, the LaunchDaemon will not be bootstrapped until
> **an admin** approves the LaunchDaemon in System Settings.

So the question as filed has a misleading answer. `register()` succeeds for anybody and parks the
service in `.requiresApproval`. The **approval** is the gate. A standard account can build a Windows
stick start to finish — that path writes unprivileged and registers no daemon — and **cannot
complete the macOS path unaided**.

Worse, `ensureReady()` sits *after* the download in `runMac`, so that account would meet the wall
after fetching ~14 GB. And all three strings for that moment said *"**your** approval"*, naming
nothing they would have to go and find.

Fixed: `AdminRights` reads `admin` group membership; `InstallPreflight` gains a third pre-erase
question beside app-replaced and USB-access; a warning banner appears at drive selection, before the
download, and suppresses the "macOS will ask **you**" note so the screen cannot contradict itself.
The three strings and the README table now name the administrator requirement.

**It warns rather than blocks.** "An admin approves" does not say whether System Settings offers a
standard user an auth sheet an administrator could fill in beside them. Refusing to start would
claim an answer the documentation does not give.

The reading is pinned in both directions **without a second account** — `/etc/group` ships
`admin:*:80:root`, `nobody:*:-2:` and `daemon:*:1:root`, so root is an administrator and the service
accounts are not, on this machine and on a CI runner alike. Three mutations, all biting: reading the
primary group instead of memberships, treating a nil reading as a denial, and warning on the Windows
path.

### The queued preview fix would not have worked

The plan of record was "a library target plus a thin executable — a `Package.swift` change". Before
paying for it — 21 test imports and 11 mutation anchors — a five-line probe view was dropped into
`BootItShared`, which is **already a library target**, and previewed.

Same error. *Still naming the executable target*, for a file that was not in it.

| View's target | Scheme | Renders? |
|---|---|---|
| executable | `BootIt-Package` | no |
| **library** | `BootIt-Package` | **no** — error still names the executable |
| **library** | **`BootItKit`** | **yes** |

Xcode resolves the preview **host from the scheme**, not from the target the view lives in. The
package scheme contains every target, finds the executable, and tries to host previews in it. A
library target only helps once a scheme exists with no executable in it — which needs a declared
library **product**, which the queued plan did not mention.

So the restructure was done, correctly this time: `Sources/BootIt` → `BootItKit` (library, declared
as a product), `Sources/BootIt` reduced to a thin `@main` over `BootItMain.run()`. ~40 fixtures that
had **never rendered once** now render.

Two confounds were cleared first and neither was a verdict: the destination was an iPhone on a
macOS-only package, and a brand-new target reported `"Probe.swift" not found in any targets` — an
answer about Xcode's index, not about previews. Worth naming, because either could have been written
down as the answer.

### Decisions

- **Warn, do not block, a standard account.** The unknown is real and blocking would overstate it.
- **`AdminRights` returns nil for "could not establish", never false.** A failed reading rendered as
  a warning would tell administrators to go and find an administrator.
- **`Sources/BootIt` holds exactly one file, forever.** Anything added there is unpreviewable and
  untestable by construction. Said so in the file.
- **All four products declared explicitly.** Naming any product suppresses the implicit ones, and
  `build.sh` copies both binaries out of the bin path — verified by running it, not by reading it.
- **Two design-index rows added rather than left as code comments**, with the honest-gaps section
  updated to distinguish them: both were measured or quoted from a primary source before being acted
  on, and the evidence sits at the call site. Not a design document, but falsifiable.

### The self-test had five degraded checks, and CI could only see two

The first push went red. Build, test and TSAN passed; **the mutation harness self-test
failed**. Its fixture was `Sources/BootIt/RunPlan.swift` — moved by this session's refactor.
The corpus specs had been repointed; the harness's own were not.

The path was the trivial half. The real finding is what the self-test printed:

```
PASS  a missing anchor is refused …        — Sources/BootIt/RunPlan.swift does not exist
PASS  an ambiguous anchor is refused        — Sources/BootIt/RunPlan.swift does not exist
PASS  a filter matching no tests is refused — Sources/BootIt/RunPlan.swift does not exist
```

Three checks **passed for the wrong reason**. Each expects `NOT-APPLIED`, and a file that
is not there returns `NOT-APPLIED`. So they were no longer testing missing anchors,
ambiguous anchors or empty filters — they were all testing the same thing, and saying PASS
while doing it. Only the two cases expecting something *other* than `NOT-APPLIED`
(`NOT-COMPILED`, `SURVIVES`) could fail, which is the only reason CI caught anything at all.

That is precisely the failure the harness exists to prevent, one level up: a check that
certifies a property it is no longer exercising, with no symptom.

Fixed by asserting the fixture exists **before** the cases run, and refusing outright if it
does not — with a message naming the three cases that would otherwise pass hollow. Falsified
both ways: pointing `target` at a moved path exits 1 without running the cases, restoring it
exits 0. The seven checks now report seven distinct reasons rather than three copies of one.
`--self-test` was added to the local receipt too, so this cannot next be caught only by CI.

### Issues discovered

- **A queued lesson was partly wrong and is now corrected in place.**
  `swiftpm-view-coverage-without-uitests` recommended `#Preview` fixtures and checked that they
  *compile*. Compiling was never the question — BootIt's forty compiled for four sessions and
  rendered zero times. Corrected, linked to the new candidate, and kept rather than deleted, because
  the extraction advice around it still holds.
- **`swiftlint lint --strict` from the repo root lints 75 files and reports 31 violations**; from
  `mac/` it lints 47 and reports none. The config's `included: Sources` resolves against the cwd, and
  when it matches nothing SwiftLint falls back to linting everything below. CI sets
  `working-directory: mac`, so this is not a live gap — but the failure is silent in the wrong
  direction, and anyone running the documented command from the wrong directory gets 31 errors that
  are not theirs. **Not fixed:** scoping `included` to `mac/Sources` would break the CI invocation.
  Recorded rather than half-fixed.

### Test results

241 tests, 0 failures (233 at session start). SwiftLint strict: 0 violations, 48 files. 0 compiler
warnings from a fully cleaned tree, enforced. Full suite TSAN-clean. `build.sh` run end to end: the
app assembles, is arm64-only, embeds the helper, and the release binary contains **zero** preview
symbols — checked against the binary's own timestamp, because a stale `dist/` would have answered
just as confidently.

**Eleven mutation checks, all biting** — the three new ones plus the eight existing, every anchor of
which moved in this session's refactor. That is the case `bin/mutation-check.py` was committed for
last session, arriving one session later: re-running the corpus after a move was one command instead
of a re-derivation.

Not covered by tests, and said so: whether System Settings offers a standard user an authentication
sheet for the Login Items switch. That needs a second account and is the only part of the
administrator question a test cannot reach.

### Next session should start with

1. **Nothing carried.** Both multi-session questions are closed, no code is queued, the design index
   has rows for both new decisions, and the queue validates clean.
2. **The one remaining unknown, if it is ever worth an account:** does a standard user get an auth
   sheet on the Login Items switch, or is it simply unavailable? It changes the warning's wording
   from "someone who administers this Mac has to approve it" to "an administrator can approve it
   here, now" — a real improvement, and not a blocker.
3. **v3.3.0 is still what GitHub ships**, and this session changed user-facing copy and the package
   layout. A release is the next thing with outside consequences.
4. **`AppModel`'s pipeline is still untested as sequencing** — recorded two sessions ago as a
   deliberate skip with reasoning. The trigger should be a bug in the sequencing, not a line count.

[promote-spine: "human-gated" is a claim about a method, not about a question — once written down it reads as a verdict and the item stops being reconsidered; ask whether a primary source already answers it, and whether the PLAN attached to it rests on a premise a cheap probe could falsify first]

[promote-profile:swift: Xcode resolves a SwiftUI preview's HOST from the selected scheme, not from the target the view lives in — so moving views into a library target does nothing on its own; a package needs a declared library PRODUCT so a scheme exists containing no executable, and the error keeps naming the executable target until it does]

[promote-profile:swift: `SMAppService.daemon(...).register()` is not admin-gated and succeeds for a standard user — it parks the service in `.requiresApproval`, and Apple's header says only an admin can approve it, so an app that only checks whether registration failed reports success to a user who can never finish]

[promote-spine: when a warning depends on reading the environment, return nil for "could not establish" and never false — a failed reading rendered as a finding tells administrators to go and find an administrator, and the wrong direction to fail is the confident one]

[promote-spine: verify a build artefact against its own timestamp before believing what you read out of it — a relative path to `dist/` answers just as confidently from a stale bundle as from the one just built]

[promote-spine: when several test cases assert the SAME expected value they can collapse into one silently — BootIt's self-test had three cases for "missing anchor", "ambiguous anchor" and "empty filter", all expecting NOT-APPLIED, and a moved fixture satisfied all three for a fourth reason while printing PASS; assert the fixture exists before the cases, and treat identical detail strings across passing cases as the smell]

## 2026-08-04 (session 3) — the carried item, and the queue that could never have drained

**Commits:** `9290bfe` → `49e0b37` (6 this session), all pushed.

**CI:** green, SHA-anchored to `4d718bf` (`headSha` verified equal to `git rev-parse HEAD`). Both
workflows green on the final tree: run `30914852075` (CI — all eight steps ran, **none skipped**,
including the new warnings-as-errors build and the mutation-harness self-test) and run
`30914851812` (Design index). The earlier mid-session anchor was run `30901164869` at `49e0b37`.
**Local:** receipt `.claude/receipts/bootit-green.build-test-lint.receipt.txt` — **233 tests, 0
failures** (221 at session start), 0 SwiftLint violations across 46 files, **0 compiler warnings**,
full suite ThreadSanitizer-clean, design-index lint green. From `swift package clean`, and now with
`-Xswiftc -warnings-as-errors`, so the warning count is enforced rather than read.

### The headline

The previous session left exactly one carried code item and said "nothing else is outstanding".
That was true of the code and **false of the repo**. `leme-promotion-digest --validate` was
reporting **22 errors, every one of them BootIt's**, and every one the same: `missing gate:`.

That is handshake step 1 — the origin repo's own duty, and `_leme` cannot land a candidate that
fails validation. So the twenty-two lessons this project has been capturing since 31 July could
**never have drained**, and no session-start message said so; the digest reported them as pending,
which reads as waiting rather than as blocked. Four sessions of capture, none of it landable.

Fixed: all 22 carry a concrete `gate:` now, and BootIt validates clean. Federation errors 162 → 140.

### The carried item was a structural hazard, not a slow function

`checkWhetherAppWasReplaced()` ran a synchronous `stat` on the main thread on every
`didBecomeActive`. The item was queued as "never profiled with a slow network volume as the
bundle's parent" — but there is no measurement that makes a blocking main-thread filesystem call
against a remote volume safe. Run from an SMB share whose server has gone away, that `stat` blocks
for the mount's timeout, tens of seconds, every time the app comes to the front.

So it was not profiled; it was moved. The reading now runs on a private serial queue — private
rather than global so one hung mount blocks one thread nothing else waits on — and two guards keep
it from piling up: the flag is latched, so once set there is nothing left to learn, and at most one
reading is ever outstanding.

Three tests assert the property that makes the speed irrelevant, driven by a fixture whose readings
stall for 600 ms. **All three were mutation-checked, each on a tree proven to compile first:**
restoring the synchronous read fails two of them, dropping the in-flight guard fails one, dropping
the latch fails one.

### The AppModel second pass, answered rather than performed

Queued as "consider whether `AppModel` needs a second pass" on the basis that it still owns
navigation, disks, the pipeline and progress. **The line-count case has gone** — it sits well inside
its budget, and the previous pass already admitted its last extraction was shaving to hit a number.

The case that would have justified it anyway was coverage: extracting `CatalogModel` is what made
the supersede logic reachable, and two mutations then survived the whole suite. **That argument does
not transfer.** `runPipeline` / `runWindows` / `runMac` are almost entirely sequencing of five
concrete collaborators, each already tested; making the sequencing testable means injecting all five
into the one code path that erases a drive, and the entire yield would be asserting that mocks are
called in order.

What *was* untested in there was not the sequencing — it was two value-returning decisions, and
neither needed the pipeline moved:

- **The progress-ring arithmetic.** Where the write lands on the ring, including the case where the
  installer was already in `/Applications` so the download owns none of it. Zero tests, on a bar
  that has shipped three wrong answers.
- **Cancelled versus failed.** Built from three separate ternaries on one flag — three chances for
  one to be edited alone — inside a `catch` reachable only by cancelling a real forty-minute write.

Both now live in `RunPlan` as pure functions with 9 tests. **Five mutations, five bites**, each
build-verified: charging the ring for a reused installer, charging a local source as a download,
swapping the two platform weights, reporting our own SIGTERM as the failure, and opening the log on
a cancellation.

### Two gates added, each proven to fail before being trusted

- **`-Xswiftc -warnings-as-errors`** in CI, on build and test. "0 compiler warnings" has been an
  unbacked claim in this repo twice, once asserted in the log while the cited receipt contained one.
  Falsified both ways: an `let unused = 1` planted in `RunPlan.swift` makes it exit 1 naming the
  line, while a plain `swift build` on the identical tree prints **ten** warnings and still reports
  "Build complete" with exit 0.
- **`bin/design-index-check.sh`** + `docs/DESIGN-INDEX.md` (B-DESIGNCTX, owed since adoption). In
  its own ubuntu workflow, not in `ci.yml` — partly cost, mostly because `ci.yml` carries
  `paths-ignore: '**/*.md'`, so the commit that lands a new synthesis with no index row would be the
  one commit that never ran the check. Falsified both ways: a planted synthesis exits 1 naming it, a
  missing index exits 1.

### Decisions

- **Nine of the twenty-two candidates moved off L2/L3 down to L4 + `fdd-field`.** L2 means "a
  mechanical gate carries this"; if none exists, L2 is the over-claim the schema exists to prevent.
  Four moved *up* to a real `test:` path that already pins them, and one — `try` on a non-throwing
  ObjC method — moved to `build-setting:-warnings-as-errors`, which is why that gate got built this
  session rather than cited as an intention.
- **Nothing cites a gate that cannot be run.** A `test:` path or a build flag that does not exist is
  the same unbacked claim these lessons are about.
- **The design index records four subsystems with no design document at all**, rather than omitting
  the rows. That is the true state of a v3.3.0 app with one gated decision.

### Issues discovered

- **The queue's own reporting hid the blockage.** Session-start prints pending counts and a drain
  budget; it does not print `--validate`. Twenty-two unlandable candidates and four sessions of
  capture presented identically to twenty-two landable ones.
- **`_leme` still owes 1 reconcile-close elsewhere**, and the +43 drain overage is federation-wide.
  BootIt cannot clear either from here — it can only stop being the reason its own share is stuck,
  which is what this session did.

### Test results

233 tests, 0 failures (221 at session start). SwiftLint strict: 0 violations, 46 files. 0 compiler
warnings from a fully cleaned tree, now enforced. Full suite TSAN-clean.

**Eight mutation checks, every one build-verified before its result was believed** — the harness
asserts the mutated tree compiles, because a patch that silently fails to apply reports SURVIVES and
reads as "this test does not bite". All eight bit; none survived. They are committed as a corpus and
reproduce identically through `bin/mutation-check.py`, which is what makes that claim re-checkable
rather than a number in a log.

Not covered by tests, and said so rather than faked: whether a real stalled SMB mount behaves like
the 600 ms fixture. The fixture proves the main thread is not blocked *by this code*; it cannot
prove what a particular network filesystem does under failure.

### Two questions had been dropped, not answered

Asked "what is left", and the honest answer was not the one this log had been giving. Each session's
"next session" list has only ever carried forward from the session immediately before it, so an item
that was not picked up in the very next session **left the record silently**. Two did:

- **Is `SMAppService` registration admin-gated?** Raised 2026-08-03, never tested, never mentioned
  again. It decides whether a *standard* (non-admin) macOS account can approve a system-wide root
  daemon — that is, whether BootIt works at all for a non-admin user. ~5 minutes on a test account.
  The only open question with a user-facing consequence.
- **Does Xcode render `#Preview` for a SwiftPM *executable* target?** Raised 2026-08-01, unresolved.
  29 preview fixtures sit behind `#if DEBUG` on the assumption that it does. If it does not, they
  are dead weight and the fix is a library target plus a thin executable — a `Package.swift` change.

Neither was closed and neither was decided against; they were simply not repeated. This section
exists so they stop falling off. **Both are human-gated** — one needs a second account, the other
needs Xcode open — which is exactly why they kept slipping past sessions that were writing code.

### The mutation harness became a committed tool

Flagged as an automation shape and then built in the same session, because the flag was accepted.
Three sessions and ~27 mutation checks had each hand-rolled the same throwaway script with the same
gotcha — build-verify before believing SURVIVES — which is itself one of the queued lessons.

`bin/mutation-check.py` reports **four verdicts, not a boolean**: `BITES`, `SURVIVES`,
`NOT-APPLIED` and `NOT-COMPILED`. The last two exit non-zero exactly like `SURVIVES`, because a
verdict you cannot believe must never be quieter than one you can. The eight mutations from this
session are committed as a corpus in `mac/mutations/`, so re-running them after a refactor that
moves their anchors is one command rather than a re-derivation — which this repo has already needed
once.

`--self-test` runs in CI and checks **both** directions, because both failures are silent:

- Four refusals — missing anchor, ambiguous anchor, a filter matching no tests, a missing file.
- A tree that does not compile → `NOT-COMPILED`, the lesson the harness exists to carry.
- And the more dangerous one: **real code, really mutated and compiled, under a filter that does not
  cover it, must report `SURVIVES`.** A harness that can only ever say `BITES` is not conservative —
  it certifies every behaviour as tested, including the ones that are not, with no symptom at all.

That turns `a-mutation-check-must-verify-its-own-build` from `L4 + fdd-field` into
`L2 + test:bin/mutation-check.py --self-test` — a real gate rather than an intention. Only the
self-test runs in CI; the corpus is eight builds plus eight filtered runs on a 10x runner, and it is
the thing you run deliberately when tests change.

### Next session should start with

1. **`SMAppService` admin-gating** (above). Small, human-gated, and the only open item that can
   change whether the app works for a class of users.
2. **The Xcode preview question** (above). Small, human-gated, decides whether 29 fixtures earn
   their place.
3. **Everything else is closed.** No code is carried, both flagged federation items inside BootIt's
   boundary are closed, and the queue validates clean.
4. **`AppModel`'s pipeline is still untested as sequencing.** Recorded above as a deliberate skip
   with its reasoning, not an oversight. If it is ever revisited, the trigger should be a bug in the
   sequencing itself, not the line count.

## 2026-08-04 (session 2) — the drive ran, the measurement overruled the model, and v3.3.0 shipped

**Commits:** `1525e6e` → `9ea5b08` (6 this session), all pushed.

**CI:** green, SHA-anchored to `9ea5b08` (`headSha` verified equal to `git rev-parse HEAD`).
**Local:** receipt `.claude/receipts/bootit-green.build-test-lint.receipt.txt` — **203 tests, 0
failures** (173 at session start), 0 SwiftLint violations across 43 files, **0 compiler warnings**,
full suite ThreadSanitizer-clean. Receipt now runs from `swift package clean`, so a cached warning
cannot pass as an absent one.

### The headline

**The first instrumented hardware run happened**, and it settled three open questions — one of them
against the tri-model prediction. The trace is committed as a fixture and replayed by
`RecordedRunTests`, so three sessions of claims about copy progress are now tests that fail in
milliseconds instead of notes checkable only by a 40-minute human-gated write.

**The bug that shipped three times, finally recorded rather than inferred.** Filesystem used-bytes
reaches **99.9% of its final value at 310 s — 18% of the way through** a 28.8-minute run. At that
instant the drive had written **12.7%** of what it would write and **23.6 minutes remained**. It
then does not move for over fifteen minutes. No clamp rescues that: `df` measures something that
finishes long before the drive does.

### Question 1 is closed, and the prediction was wrong

Two of three tri-model legs argued `proc_pid_rusage` counts writes into the unified buffer cache,
so it would sprint to the payload size in ~2 minutes and then freeze — the `df` failure one layer
up. **It did neither.** It tracked the device counter for the whole run and finished **1.2% below
it**. On this hardware it would have served perfectly well as a numerator.

The design did not change and should not: the reason there is no percentage is that the
**denominator** is unknowable before the run, and a second well-behaved numerator supplies none.
But a supporting argument was false, and it is recorded as false. **Two of three models agreeing
is not evidence** — that is the whole reason the run was worth doing.

Question 3 also closed: the tail is **transfer, not flush** — 1519 MB at 9.2 MB/s in the 166 s
*after* `createinstallmedia` printed "100%". Question 2: **1.048**, against M1's 1.058 from an
assumed baseline. Question 4 (sleep / re-enumeration) is **still open and marked untested** — this
run had neither, and saying it passed would be the exact error this log has made before.

### Measured before it evaporated

The stick was read the moment it was plugged in, before anything wrote to it: **871,936 bytes / 59
write operations** while merely mounted. A freshly attached drive does **not** start at zero.
That is M3, and it closes the gap M1 named as the reason its own confidence was LOW-MEDIUM — "the
baseline at run start is assumed, not measured". It is no longer assumed.

### The sanitizer became a gate, and earned it within the hour

`swift test --sanitize=thread` runs in CI now, proven in **both** directions before being trusted:
restoring the unsynchronised `AppModel.ingest` makes it exit 1 with 8 race warnings; the fixed tree
exits 0. In the existing job, not its own — a second macOS runner bills at 10x where this reuses
the checked-out tree for 21 s.

It then caught a race in a **test written minutes earlier** — a plain counter touched from two
probe threads. Not production code, but a racing test fails that gate on somebody else's unrelated
change, which is a worse debt than the one it was written to prevent.

### Both pre-flight questions now asked before the user commits

- **App replaced while open.** BootIt ships as a DMG, so updating is a drag-and-replace, usually
  done *because* the user hit something — with the old copy still open. The running process then
  reads the new bundle: `isStale()` fingerprints the *new* helper, installs it, and leaves the old
  app talking to a newer daemon across a changed protocol. Noticed on `didBecomeActive` for one
  `stat`. **Inode, not mtime** — Finder, `ditto` and `cp -p` all preserve timestamps, and there is
  a test pinning exactly that. Latches, survives `reset()`, never interrupts a run in flight.
- **Full Disk Access.** The answer already existed behind Help → Privileged Helper… → Test USB
  Access, where no first-run user looks. Now runs on drive selection — but **only when the daemon
  is already installed**, because `AccessDiagnostics.run()` calls `ensureReady()`, which registers
  it. Probing regardless would install a root LaunchDaemon because someone plugged in a stick.

`probeWrite` now routes through `decode()`, which is what makes the FDA button correct rather than
guessed — a TCC denial and a read-only volume are both refusals, and only one is fixed in that
settings pane. That closes the carried item, but it was done because the banner needed it.

### Decisions

- **Kept `fileURL`; `parseTrace` earned its keep.** `parseTrace` now has a real caller — replaying
  the recorded run. `fileURL` has four test callers and is the only thing making the writer's
  output observable; removing it would duplicate path construction into the tests and stop checking
  that the writer writes where it claims. **Not the same shape** as the dead code removed twice
  before (`pruneOldTraces`, `helperVersion`), which was unreachable rather than test-only.
- **Decomposed `AppModel` rather than raising the lint limit.** It sat at **396 of a 400-line
  budget**; the feature nets +6 after extracting `InstallPreflight`, `CopyRing`, and two selection
  helpers onto `MacOSGroup`. Honest caveat: by the last extraction I was shaving to hit a number.
- **Did not change the design on the strength of the falsified prediction.** Recorded it and moved
  on. Changing a shipped decision because one supporting argument fell over — while the load-bearing
  one (no denominator) still holds — would be the fourth wrong answer, not the first right one.

### Issues discovered

- **Last session's log claimed "0 compiler warnings" while citing a receipt that contained one.**
  `CopyTraceWriter.swift:89`, `result of 'try?' is unused`, present the whole time. Second time in
  two sessions a claim in the record was contradicted by the artefact it pointed at. Fixed, and the
  receipt now rebuilds from clean so this cannot recur silently.
- **I called two things early on partial data.** Said `processBytes` was "flat at 0" after 12
  samples (it was zero only before bulk copying started), and wrote two assertions from assumption
  — that `df` goes *blind* (it goes **static**; only 16 samples were nil) and that it stays frozen
  to the end (one tick at unmount). The tests caught both. That is the cheapest place this project
  has ever caught that class of error, and it is the class the trace format exists to prevent.
- **`SMAppService` approval persists across a same-signature update.** v3.1.0 → this build
  re-registered the helper with **no prompt**. Worth knowing before shipping an update.
- **`AppModel` is a god object at its ceiling.** Four lines of headroom on a class doing
  navigation, catalogue, disks, pipeline, progress and now pre-flight. A real decomposition
  deserves its own change, not smuggling inside a feature.

### Test results

203 tests, 0 failures (173 at session start). SwiftLint strict: 0 violations, 43 files. 0 compiler
warnings from a fully cleaned tree. Full suite TSAN-clean, and TSAN is now enforced in CI.

**Nine mutation checks, each build-verified before its result was believed** — the harness asserts
the mutated tree compiles, because a patch that silently fails to apply reports SURVIVES and reads
as "this test does not bite". One genuinely survived (`reset()` not clearing the access warning)
and got a test; the rest bit first time. All nine were re-run after the `InstallPreflight`
refactor, since the anchors moved and the earlier results no longer certified the shipped code.

Not covered by tests, and said so in the code rather than faked: the `status == .enabled` guard
that stops a drive click from installing a root daemon. Asserting it under XCTest would assert
`SMAppService`'s behaviour; removing it to watch a test fail would register a daemon on the machine
running the suite.

### After the log above was written — the session kept going

Four more commits, `51575c9` → `071d444`, and **v3.3.0 shipped**. All three items this log had
queued for "next session" were done in this one.

**The eject error was inventing its reason.** A finished run said "Couldn't eject SanDisk 3.2Gen1
— a file on it may still be open." `lsof` showed nothing open on the volume and
`diskutil eject disk4` succeeded from a shell moments later. The sentence was hardcoded and
printed for every failure, in the grammar of a diagnosis, while diskutil's own output — which
names the process holding the disk, "Dissenter PID=442 (mds)" — was discarded.

**Third instance of this exact mistake.** `20e1874` stopped guessing at the helper's reason for
refusing; `AccessDiagnostics` stopped rendering every daemon refusal as "enable Full Disk Access";
this was the eject path. It also rendered as grey `.footnote` text under a green tick, so an
action that did not happen read as a hint. It is a warning banner now.

**Question 4 closed, and it needed five minutes rather than another 40-minute run.** The hazard is
a property of the counter, not of a copy in flight, so it was measured on an idle drive:

| Event | before | after | |
|---|---|---|---|
| Unplug + replug | 21,261,767,168 | 99,840 | **resets** |
| Sleep + wake | 99,840 | 247,808 | **survives** |

Two different hazards; only one needs handling, and the existing handling is right. ChatGPT's leg
raised this and neither other leg did. See M5.

**`AppModel` decomposed: 396 → 345.** Fifty-five lines of headroom instead of four. The catalogue —
twelve published properties, three loaders, four derived accessors — moved to `CatalogModel`, a
value type in one `@Published` property, the same shape as `InstallPreflight`.

The find: **the supersede logic had no tests, in either place.** It lived as a `catalogLoadID`
compared inside each completion handler, and could not easily have been tested where it was —
exercising it meant driving a live Microsoft fetch through a class that also owned the write
pipeline. Two mutation checks survived the whole suite. Extraction is what made it reachable.

One of those mutations then survived a second time, because my first test asserted the wrong
thing: that a pre-reset reply is discarded, which both a carried and a restarted load counter
satisfy. The real hazard is a **collision** — a restarted counter hands the first fetch after a
reset the same id as one still in flight, so the older reply is accepted as the answer to the
newer question.

**v3.3.0 shipped, and was verified rather than trusted.** All twelve workflow steps ran with none
skipped — the silent-skip failure mode this workflow has form for. The published DMG was
downloaded and checked: `accepted`, `source=Notarized Developer ID`, ticket stapled, app inside
3.3.0 / arm64 / helper embedded, durable URL resolving 200.

**221 tests** at close (173 at session start), TSAN-clean, 0 lint violations, 0 compiler warnings.
**Fourteen mutation checks** across the session, every one build-verified before its result was
believed; three genuinely survived and got tests.

### Next session should start with

1. **The bundled-helper staleness check runs on every `didBecomeActive`** — one `stat`, measured as
   negligible, but never profiled with a slow network volume as the bundle's parent. The only
   carried item, and a small one.
2. **Nothing else is outstanding.** All five queued items from the previous session are closed, all
   four §5 research questions are answered, and v3.3.0 is out. The next real work is new work.
3. **Consider whether `AppModel` needs a second pass.** 345 of 400 is comfortable, but it still owns
   navigation, disks, the pipeline and progress. The catalogue was the largest coherent slice; the
   write pipeline is the next one, and a bigger job than this was.

**Federation note:** queue-drain budget was over ceiling at session start (255 > 221, +34 owed) and
this session adds 3. Capture kept deliberately narrow.

[promote-spine: a prediction that survived three independent models can still be false, and only measurement settles it — BootIt's tri-model gate had two of three legs predict `proc_pid_rusage` counts buffer-cache writes and would race to payload size then freeze, and the first instrumented run showed it tracking the device counter to within 1.2% for 29 minutes; the decision it supported was correct for a *different* reason (no knowable denominator), so the design stood, but "two of three models agreed" was recorded as evidence when it was consensus, and consensus among models trained on overlapping data is not independent confirmation]

[promote-spine: a test written from assumption fails in seconds where the same assumption in shipped code fails after forty minutes — writing assertions about BootIt's recorded run surfaced two wrong beliefs immediately (that filesystem used-bytes goes *blind* mid-run when it actually goes *static*, and that it stays frozen to the end when it ticks once at unmount), both of which had already been stated confidently in prose; the discipline is to assert the number you believe BEFORE looking at it, because a test is the cheapest place to be wrong and prose is the most expensive]

[promote-spine: a CI gate must be proven to fail before it is trusted to pass — BootIt added `swift test --sanitize=thread` to CI and verified it in both directions first, restoring a known race to confirm exit 1 with 8 warnings and the fixed tree to confirm exit 0, because the same repo had already shipped a release workflow whose signing steps silently skipped and reported success; a step that cannot go red is worse than no step, since it converts an unchecked property into one everybody believes is checked]

## 2026-08-04 — the progress bar stopped claiming a percentage, and review found the race

**Commits:** `06e184e` → `db3d349` (3 this session), all pushed.

**CI:** green, SHA-anchored to `db3d349` (run `30855199681`, `headSha` verified equal to
`git rev-parse HEAD`).
**Local:** receipt `.claude/receipts/bootit-green.build-test-lint.receipt.txt` —
**173 tests, 0 failures**, 0 SwiftLint violations across 40 files, 0 compiler warnings.
(143 tests and 34 files at session start.) Additionally **ThreadSanitizer-clean** across the full
suite, which is new and is the only reason this session's worst bug was provable.

### The headline

Implemented the tri-model decision from `docs/research/copy-progress-reporting-*`: **the macOS copy
phase no longer claims a percentage.** The ring goes indeterminate for the opaque stretch and
carries throughput, bytes written and elapsed beside it — the liveness figures BootIt has never had,
and the actual answer to the question three previous "fixes" kept mis-hearing as *what percentage is
done*.

The reader moved from filesystem used-bytes to the device's own `IOBlockStorageDriver` counter, and
the state machine became a pure function of a sample stream. Every run now writes a trace to
`~/Library/Logs/BootIt/`. That shape is the point: the three previous versions could only be
falsified by a 40-minute human-gated write, which is precisely why three wrong answers shipped.

### Evidence found on a stick that was still plugged in

The SanDisk from the 2026-08-03 run was still attached with its counter never reset — perishable
evidence, captured before it evaporated. Both readings are in `docs/research/copy-progress-measurements.md`,
the ledger for the questions synthesis §5 left open.

- **Device wrote 21.266 GB to land 20.105 GB of payload — a ratio of 1.058.** Write amplification is
  therefore not disqualifying, but it runs in the dangerous direction: a payload denominator would
  reach 100% about 6% early, which is exactly the failure ChatGPT's evidence bar names. Gemini's 95%
  clamp is load-bearing, not decoration. Confidence LOW-MEDIUM — the baseline at run start is
  assumed, not measured, which is what the new instrumentation fixes.
- **An idle *mounted* volume ticks its journal ~275 B/s.** Zero drift over two minutes, 164,864 bytes
  over ten.

### Two bugs found by measuring rather than by reasoning

- **The journal noise broke my own state machine.** It treated *any* counter increase as the drive
  moving, so a drive that had genuinely wedged — but was still mounted — would never be reported as
  wedged, because the noise kept resetting the silence clock. There is a 1 MB `movementFloor` now:
  0.11 s of real writing at the measured rate, an hour of journal noise. **No unit test written at
  the time would have caught this**; it came from reading the counter twice ten minutes apart.
- **A grep for call sites caught two dead paths, one of them created this session.**
  `pruneOldTraces` had exactly one occurrence — its own definition. Tested, and called by nothing;
  traces would have grown without bound. Now called at launch.

### The race independent review found

`senior-swift-review` returned **no-go on "done as merged"**, and was right. `AppModel.copyModel` —
a struct holding an `Array` — was mutated from two threads with nothing synchronising them:
`ingest()` folded each sample in on whichever thread delivered it (the XPC connection's own) while
`endCopyReporting()` reset the whole reducer from `worker`.

**Not argued — observed.** Under `swift test --sanitize=thread` the new seam tests reported the race
in `CopyProgressModel.ingest` and `.track` and killed the test process with signal 5. After the fix
the full suite is TSAN-clean, and restoring the old ordering brings the warnings straight back.

The window is **the tail of every run**, not an exotic one: `DispatchSourceTimer.cancel()` does not
interrupt a handler already running, and the daemon stops sampling only after sending the reply that
unblocks the app. A dropped connection opens it wider.

The pointed part: I had named the IOKit retain/release as the top risk in the review brief, and it
turned out to be the soundest part of the diff. **The defect was in the plain-Swift glue — because
the reducer has 14 tests and the seam feeding it had none.**

Two further findings from the same review, both taken:
- Handlers on the `PrivilegedHelper` singleton were replaced only at the *start* of the next run,
  never cleared at the end of one, so a late sample reached closures belonging to finished work —
  reopening a closed trace file and reviving a liveness line. They detach in a `defer` now, and the
  trace writer latches shut.
- The previous commit deleted `currentHelperVersion()` as one-occurrence dead code **and left the
  `helperVersion` XPC method in**, under a comment I wrote claiming it was the fallback for a daemon
  too old to know what a fingerprint is. Nothing implemented that fallback. A comment describing an
  intention made it a third instance of the very thing that commit claimed to be removing.

`security-review` returned **go, no blockers** — the signature pinning removes the threat actor from
the model for the new XPC callback, the trace is safe to attach to an issue, and pruning cannot be
traversed. Its one note (the trace directory is not checked for being a symlink) is same-user-only
and now recorded as a comment naming the ceiling.

### The release secrets never vanished

Queued task #5 has an answer and it is that the premise was wrong. v3.1.0's DMG was notarised
**locally** by `package.sh` and uploaded **by hand** (`uploader=iwannabesurfing`, 11:16:53Z) — four
seconds *before* the tag's CI run started at 11:16:57Z. That run skipped "Write notarisation API
key", "Import Developer ID certificate" and "Publish GitHub release", and reported **success**.

Last session read the notarised DMG as proof the secrets had existed and concluded they had been
deleted. The DMG only ever proved the local keychain worked. The `bootit-distribution` memory
recorded the true state correctly on 31 July — "which they don't yet — so releases are currently
published by hand" — and has been updated so this is not re-opened as a mystery.

It cost nothing this time, because restoring secrets that were never there is the same action as
adding them. But it went into the record as an observation when it was an inference, and the next
session inherited it as fact.

### Decisions

- **Kept the instrumentation** after the user asked whether ~1,000 lines was real or accretion.
  Presented the honest split: ~90 of 319 new code lines are evidence-collection the feature does not
  need to work, and 2 of 30 new symbols (`parseTrace`, `fileURL`) have no production caller. His
  call, made with the counter-evidence in hand rather than a defence of the diff.
- **No hardware run this session**, at the user's direction. The trace writer is always-on, so the
  next real run produces fixture #1 without anything special being done.
- **Deleted the payload-estimate machinery rather than leaving it unused.** It existed to be the
  denominator of a percentage no longer claimed. Its measurements survive in the fixture and the
  research record; four tests that pinned the rejected design went with it.
- **Fixture #1 is a reconstruction, labelled as one.** Six measured points, linear interpolation
  between them, and the mutation check only depends on the measured points. To be replaced by a
  recorded trace at the first instrumented run.

### Issues discovered

- **My mutation harness reported a false "survives".** The first M8 run said the `clearHandlers`
  mutation survived; it had never applied, and the harness could not tell a broken mutation from a
  passing test. Re-run with a build check, it bites. **Every "survives" result from a mutation
  harness that does not verify the build is worthless.**
- **`parseTrace` and `fileURL` have no production caller** — the trace format's reader half and a
  test-support accessor. Kept deliberately (a format nothing can read is worse), but they are the
  same shape criticised elsewhere in this log and should not drift into being forgotten.
- **TSAN is not in CI.** Three threading bugs have now shipped in this one subsystem — a cancel on
  the queue it was meant to interrupt, a poller holding a global-pool thread for 40 minutes, and
  this race. The third was caught by a two-second sanitizer run that nothing obliges anyone to do.

### Test results

173 tests, 0 failures (143 at session start). SwiftLint strict: 0 violations, 40 files. 0 compiler
warnings. Full suite TSAN-clean. Receipt committed.

**Nine mutation checks proved the new tests bite:** filesystem used-bytes as the source (7 tests),
inferring "finishing" from silence (2), keeping a run total across a counter reset (1),
re-introducing a percentage (1), dropping the baseline subtraction (2), removing the movement floor
(1), mutating the model off-main again (TSAN, 8 warnings), `clearHandlers()` as a no-op (1), and the
trace-writer latch removed (1).

Not covered by tests, verified by inspection only: the `clearHandlers()` call site in
`MacInstaller.write` (a `defer`, checked by grep — there is no seam that would let a unit test
observe it), and the end-to-end daemon→app sample path, which has never run against real hardware.

### Next session should start with

1. **Stale-app detection + first-run Full Disk Access onboarding.** Unchanged as the largest
   remaining UX defect now that the progress work has landed. "BootIt was updated while running,
   quit and reopen" and "BootIt needs Full Disk Access before it can write" are the same class of
   message, both belonging before the user commits to erasing a drive. Design call — options range
   from a launch-time mtime watch to catching the XPC mismatch.
2. **Add `swift test --sanitize=thread` to CI.** Flagged this session and not yet actioned. Three
   threading bugs in one subsystem, the last found only because a sanitizer was run by hand.
   Converts a repeat-offender bug class from hand-verification to green-or-red.
3. **The first instrumented hardware run.** Human-gated, ~40 minutes, needs no code. Produces the
   real fixture #1 and settles two open measurements at once: whether `processBytes` races and
   freezes as Gemini predicts (§D2), and what the baseline actually is. **Build and install both
   halves pinned together first** — the XPC protocol changed and the helper is now version 7.
4. **Route `probeWrite` through `decode()`**, or accept that the `HelperFailure` →`HelperError`
   mapping is unit-tested only and say so in a comment. Carried from last session, unchanged.
5. **Decide `parseTrace` / `fileURL`** — keep as the trace format's reader half, or remove until
   something in production reads a trace back.

**Federation note:** the queue-drain budget was already over ceiling at session start
(250 pending > 221, +29 owed) and this session adds 4. Capture was kept deliberately narrow.

[promote-spine: when a well-tested pure core is fed by an untested seam, the bug is in the seam — BootIt's copy reducer had 14 tests and a recorded-trace replay harness while the glue delivering samples to it had none, and that glue mutated the reducer from the XPC delivery thread and the worker queue simultaneously; the review that found it went looking where the parent agent said the risk was (an IOKit retain/release walk, which was flawless) and found it where nobody had looked at all]

[promote-spine: a mutation check that does not verify the build cannot tell a broken mutation from a surviving one — BootIt's harness reported SURVIVES for a `clearHandlers()` mutation whose patch had silently failed to apply, which reads as "this test does not bite" and would have justified deleting a test that bites perfectly well; every mutation harness must assert the mutated tree compiles before believing any survival result]

[promote-spine: deleting a caller is not deleting the dead code — BootIt removed `currentHelperVersion()` as one-occurrence dead code in the same commit that left the `helperVersion` XPC method it called standing, under a fresh comment asserting a fallback capability that nothing implemented; a comment describing an intention reads exactly like a comment describing behaviour, and it converted dead code into dead code with an alibi]

[promote-spine: an inference recorded as an observation becomes the next session's fact — BootIt's log concluded that six CI signing secrets had been deleted, inferring it from a notarised DMG that had in truth been signed locally and uploaded by hand four seconds before CI even started; the memory written at the time recorded the true state and was overruled by the more recent, more confident, wrong entry, and a queued task existed for a session to investigate a disappearance that never happened]

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

### ADDENDUM — C-TRIMODEL fired on the progress indicator (post-close)

**Commit:** research files + this addendum. **Trigger:** the user, not the agent.

After the session-end push the user objected that the progress indicator had been fixed three times
with no real investigation, and asked for a triangulation. **He was right, and the objection lands
twice.** The queued task #7 — "use device I/O counters" — was a *fourth reader substitution*, and it
was queued in the same session in which I wrote, in a promotion file, that "when the same
user-visible symptom returns after a fix, suspect the source of truth, not the reader; two fixes to
the reader is the signal." I named the pattern and then repeated it in the next action.

I also overstated the evidence for that fix: I reported that cumulative device I/O counters "tracked
the real write perfectly", when what I had demonstrated was that they showed **movement**. Movement
is not progress, and I never established a baseline could produce a percentage. All three legs
subsequently dismissed the baseline objection as trivial, so that specific worry was wrong too — but
in the other direction, which is not exculpatory.

**The gate should have fired on my own judgment.** It passes all three tests: foundational (the
entire UI for 38 of 40 minutes of the app's primary operation), hard to reverse (every iteration
costs a human-gated 40-minute hardware run to falsify — which is *why* three wrong answers shipped),
and genuinely open (five materially different approaches). Queueing a patch instead of flagging is
the mis-scoping the gate exists to prevent.

**Result — `docs/research/copy-progress-reporting-*` (3 legs + synthesis, gate check passes).**

All three models independently rejected the *framing*, not the implementation. Gemini named it a
"reader substitution anti-pattern"; ChatGPT, "assuming that every long operation must be represented
as a scalar fraction complete"; Claude, "answering *what percentage* when the user asked *is this
working*". Nine unanimous decisions, three real divergences resolved.

The core resolution went **against** my own leg and Gemini's: **no macOS percentage for now.**
ChatGPT's evidence bar for a trustworthy denominator is not met on n = 1 — one instrumented run, one
stick. Ship an indeterminate ring plus explicit liveness (MB/s, bytes, elapsed, a broad range),
instrument to collect traces across a device matrix, then re-evaluate against Gemini's 5/90/5 model.
Sequencing, not permanent rejection.

Two corrections to my leg, both from converging external legs: `proc_pid_rusage` demoted from
"cross-check" to "instrument and observe" (it measures the buffer-cache layer, so it would race then
freeze exactly as `df` does — one layer up), and ChatGPT uniquely caught that device counters can
reset on detach, re-enumeration or sleep, which directly threatens the baseline subtraction all three
legs otherwise endorsed.

Task #7 rewritten to the decision. Nothing implemented — the build order starts with trace logging
and a replay harness, so the next attempt can be falsified in under a second instead of forty minutes.

[promote-spine: a lesson written into a promotion file is not thereby learned — in the same session that captured "when a symptom survives two fixes, suspect the source of truth, not the reader", the agent queued a third reader substitution as the fix; the capture step and the application step are separate, and the one that matters is checked against the NEXT decision, not the write-up]

[promote-spine: a design gate that only ever fires when the user demands it has already failed — BootIt's progress indicator passed all three C-TRIMODEL tests (foundational, hard-to-reverse because each iteration costs a 40-minute human-gated run to falsify, genuinely open) and the agent queued a patch instead of flagging it; the tell for "hard to reverse" is not just rework cost but how EXPENSIVE FALSIFICATION IS, because a decision that cannot be cheaply tested will ship wrong repeatedly]

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
