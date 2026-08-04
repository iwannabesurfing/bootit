# BootIt — DESIGN INDEX (feature → where the thinking lives)

**Purpose:** one map so anyone — especially a fresh-context session — can find the authoritative
design context for a feature *before* touching it, instead of scoping a change as plumbing and
missing the decisions around it. Per the federation's B-DESIGNCTX / PS-02 reflex, read the relevant
row's documents first.

This repo is the case study for why the reflex exists. The macOS copy-progress indicator shipped
**three wrong answers in three sessions**, each one a reasonable-looking local fix by someone who had
not read what the previous attempt established. The reasoning existed; nothing pointed at it.

**Authority order — measurement first, and that ordering was earned:**

1. **Recorded measurements** (`docs/research/copy-progress-measurements.md`, and the trace fixture
   replayed by `RecordedRunTests`).
2. **The tri-model synthesis** for that decision.
3. Its **brief and per-model legs** — working papers; they show how the synthesis was reached.
4. The **session log** (`.claude/session-log.md`) — the running record of decisions with no
   standalone document.
5. **This index** — a pointer. It never decides.

Measurement outranks the synthesis because it has already overruled one. On 2026-08-04 the first
instrumented hardware run falsified a prediction that two of three independent model legs agreed on.
The decision the prediction supported survived — for a different reason that still held — but
"the models concurred" is not evidence, and this ordering is what records that.

**Coverage rule (DESIGN-INDEX-P1):** every `docs/fdds/*.md` and every `docs/research/*-synthesis.md`
must have a row below. Legs and briefs are exempt — the index points at decisions, not their working
papers. A new synthesis or FDD adds its row in the same commit, or `bin/design-index-check.sh` fails.

---

## Feature → docs map

| Feature area | Decision / tri-model synthesis | Measurements + working papers | Where the rest lives |
|---|---|---|---|
| **macOS copy progress** — what the ring shows during `createinstallmedia`'s silent stretch, and why it claims no percentage | [`copy-progress-reporting-trimodel-synthesis.md`](research/copy-progress-reporting-trimodel-synthesis.md) | [`copy-progress-measurements.md`](research/copy-progress-measurements.md) · [brief](research/copy-progress-reporting-trimodel-brief.md) · legs: [Claude](research/copy-progress-reporting-claude-leg.md), [ChatGPT](research/copy-progress-reporting-chatgpt-leg.md), [Gemini](research/copy-progress-reporting-gemini-leg.md) | `CopyProgressModel` · `CopyRing` · `RecordedRunTests` |
| **Privileged helper / XPC** — what runs as root, staleness detection, cancellation, error reporting | _no synthesis; decisions were made under a live bug, not at a design gate_ | — | `PrivilegedHelper` · `HelperProtocol` · `BootItHelper/main.swift` · session log 2026-08-03 (Phase 0) |
| **Drive safety** — nothing preselected, selection tracked by id, destructive confirmation | _no synthesis_ | — | `AppModel.refreshDisks` · `RootView` confirmation dialog · session log 2026-08-01 |
| **Run presentation** — progress spans, and cancelled-versus-failed | _no synthesis_ | — | `RunPlan` (+ `RunPlanTests`, which is where its rules are falsifiable) |
| **Release + distribution** — Apple Silicon only, signing, notarisation, staged publish | _no synthesis_ | — | `README.md` · `mac/build.sh` · `mac/package.sh` · `.github/workflows/release.yml` |
| **Who can approve the helper** — a standard account cannot, and learns so before it downloads 14 GB | _no synthesis; the rule is Apple's, quoted at the call site_ | `SMAppService.h` (`registerAndReturnError` discussion) quoted in `AdminRights` | `AdminRights` · `InstallPreflight.warnsAboutAdministrator` · `AdminRightsTests` · session log 2026-08-05 |
| **Package shape** — why the app is a library plus a thin `@main`, and not one executable target | _no synthesis; three arrangements measured in Xcode 26.6, recorded in `Package.swift`_ | — | `mac/Package.swift` (`products`) · `BootItMain` · `Sources/BootIt/Main.swift` · session log 2026-08-05 |

## Honest gaps

Six of the seven rows above have **no design document at all**. That is the true state, recorded
rather than papered over: BootIt reached v3.4.0 with one gated design decision and six subsystems
whose reasoning lives in code comments and the session log. Those comments are unusually thorough,
but they are discoverable only by someone already reading the right file — which is the exact failure
this index exists to reduce, not one it has fixed.

Two of those rows are a weaker gap than the others, and the difference is worth naming: the helper-
approval rule and the package shape were each **measured or quoted from a primary source before being
acted on**, and the evidence sits at the call site rather than in a reviewer's memory. That is not a
design document, but it is falsifiable, which "we decided this at some point" is not.

The rows are listed anyway. A pointer to "the reasoning is in `PrivilegedHelper` and the 2026-08-03
log" is worth more to a fresh session than an absent row, and it is the honest thing to write.
