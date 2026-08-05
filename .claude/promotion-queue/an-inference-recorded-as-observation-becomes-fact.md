---
slug: an-inference-recorded-as-observation-becomes-fact
origin: BootIt
session: bootit-2026-08-04-copy-progress
date: 2026-08-04
target: spine
relevance: all — any project where an agent writes a session log, memory file or handover doc that a later session reads as ground truth
status: pending
reliability-target: L4
gate: fdd-field
hook: An inference written into a session log becomes the next session's fact, and outranks the memory that recorded the truth. BootIt logged that six CI signing secrets "were gone", inferring it from a notarised DMG that had actually been signed locally and uploaded by hand four seconds before CI started. A task was queued to investigate a disappearance that never happened, and the memory written at the time — which was correct — lost to the more recent, more confident, wrong entry.
---

## The lesson

A session found six GitHub Actions secrets absent (`total_count: 0`) and wrote:

> The six signing secrets were **gone**. They had existed on 31 July, proven by the published v3.1.0
> DMG reporting `source=Notarized Developer ID`.

The word *proven* is doing work the evidence cannot support. A notarised DMG proves **something**
notarised it. It does not identify what. In this case a local `package.sh` run using a keychain
profile did, and the DMG was uploaded by hand:

| Evidence | Time |
|---|---|
| v3.1.0 DMG asset uploaded, `uploader=iwannabesurfing` | 11:16:53Z |
| The tag's CI run **started** | 11:16:57Z |

The release was finished four seconds before CI began. That run then skipped "Write notarisation API
key", "Import Developer ID certificate" and "Publish GitHub release" — and reported **success**.

The secrets had never been added. A project memory written on 31 July said so explicitly: *"publishes
only when the signing secrets exist, which they don't yet — so releases are currently published by
hand."*

## Why the record loses to the guess

The correct information was written down, in the right place, and still lost. Three reasons:

1. **Recency.** The session log entry was three days newer than the memory. Later entries are read as
   supersessions, not as competing claims.
2. **Confidence.** "Proven by" reads as settled. The memory's phrasing was ordinary description. The
   more emphatic wording won, and emphasis had no relationship to evidence.
3. **It generated work.** The inference produced a queued task — *"Ask why the release secrets
   vanished. Restored, but the cause is unknown."* An open question is a much stickier artefact than a
   quiet statement of fact; the next session inherits the question and treats its premise as given.

The cost here was small only by luck: restoring secrets that never existed is the same action as
adding them.

## How to apply

- **In a log, mark the epistemic status of anything not directly observed.** "Observed: `total_count`
  is 0." / "Inferred: they existed before, because the DMG is notarised." Two words, and the next
  reader can re-derive rather than inherit.
- **"Proven by" is a load-bearing phrase — reserve it for something a command produced.** If the
  evidence is an artefact whose provenance you did not check, the honest verb is "suggests".
- **When a new conclusion contradicts an existing memory, that is the signal, not the noise.** The
  contradiction was visible at the time and was not treated as one.
- **Before queueing a task to explain something surprising, check the premise is real.** "Why did X
  happen" spends a future session assuming X happened. Here the whole answer was two API calls
  comparing an asset's upload timestamp with a workflow run's start time.

## Receipt

BootIt, verified 2026-08-04 from
`gh api repos/…/releases/tags/v3.1.0` (asset `uploader=iwannabesurfing`, `created_at`
`2026-07-31T11:16:53Z`) and `gh api …/actions/runs/30626480983/jobs` (run created
`11:16:57Z`; steps 5, 6 and 10 `skipped`; job conclusion `success`). The 2026-08-03 session log's
"the secrets that had vanished" section and its queued task #5 both rest on the inference. The
`bootit-distribution` memory has been corrected with the timestamps so it is not re-opened.

Note this is the *same defect class* the same repo had already promoted one day earlier as
`report-what-you-were-told-not-what-you-inferred` — that one about an app reporting to a user, this
one about an agent reporting to its own future self. Naming a pattern in a promotion file does not
prevent committing it in the next artefact you write.

## A third instance, and this one had the evidence committed beside it (2026-08-05)

Sharper than the two above, because the refutation was not merely available — it was **in the
repository, in a file added by the same session that wrote the claim**.

`InstallMediaProgress.swift` asserted in a doc comment, twice, that macOS 26's
`createinstallmedia` "emits exactly three lines, none carrying a number" during the copy. It emits
`Copying to disk: 0%… 100%`, and that line is present in `copy-run-2026-08-04.jsonl` — the trace
fixture committed the same day. `RecordedRunTests` even **quotes the line in a test docstring**
while the source file denies it exists.

Three artefacts, one repo, two of them agreeing and the third contradicting both, green the whole
time. The claim was never checked against the trace because writing a trace *feels* like having
checked it.

**The added rule:** when you record evidence, grep the recorded evidence for the claim you are
about to write next to it. A fixture is not a check. It is only a check once something reads it —
and a docstring is not something that reads it.

The cost here was two shipped defects (a ring frozen at 95% for 85% of a 30-minute run, and a
status line naming the wrong stage for the same stretch), found by a human watching the screen
rather than by 241 green tests. See [[deleting-the-mechanism-leaves-the-belief]].
