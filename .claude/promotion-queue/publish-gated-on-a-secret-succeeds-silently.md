---
slug: publish-gated-on-a-secret-succeeds-silently
origin: BootIt
session: bootit-2026-08-03-release
date: 2026-08-03
target: spine
relevance: all — any CI pipeline whose publish/deploy step is conditional on a credential being present
status: pending
reliability-target: L2
hook: A release job whose publish step is gated on `if: <secret> != ''` reports SUCCESS while publishing nothing. BootIt's six signing secrets had been deleted at some point between releases, so tagging would have built, signed ad-hoc, skipped notarisation, uploaded a 7-day artifact and finished GREEN with no release — a successful-looking run that ships nothing.
---

## The lesson

The release workflow was written defensively and, on its own terms, sensibly: without signing
credentials it still builds and uploads an artifact so the pipeline stays exercised, but it refuses
to publish an unsigned release. The gate reads:

```yaml
- name: Publish GitHub release
  if: startsWith(github.ref, 'refs/tags/') && env.MACOS_CERT_P12 != ''
```

Preparing a release, the secrets turned out to be **gone** — `total_count: 0`, no environment
secrets, no org secrets. They had existed three days earlier, proven independently: the previously
published DMG reports `source=Notarized Developer ID`, which is unreachable without them.

Had the tag gone up without checking, the run would have gone green, produced an artifact that
expires in 7 days, and created **no release at all**. The most-watched signal — the green tick —
would have been actively misleading, and the durable download URL would have quietly kept serving
the previous, broken version.

## Why it fails silently

The condition is doing exactly what it was written to do. There is no error to surface, because
"skip" is a legitimate outcome of a conditional step and GitHub renders it as a neutral grey tick
inside an otherwise green run. Nobody reads a step list on a run that passed.

The deeper error is that **one condition serves two different intentions**. On a `workflow_dispatch`
dry run, "no credentials → skip publishing" is correct and desirable. On a **tag**, it is a silent
failure: a tag is an explicit instruction to release, and degrading it to a no-op discards the
instruction rather than reporting that it cannot be carried out.

Credentials also rot in ways nothing watches: they expire, get rotated, get cleaned up by someone
tidying a settings page. Nothing fails until the next release, which may be months later, and the
failure lands as "the release didn't appear" long after the cause.

## How to apply

- **Split the intent.** Skipping publish is fine for a dry run; on a tag, missing credentials must
  **fail the job loudly**, not skip a step. Add an explicit preflight on tag builds that asserts
  every required secret is non-empty and exits 1 with the names of the missing ones.
- Never let the *only* evidence of a successful release be the job's conclusion. Verify the
  artefact exists at its public URL afterwards — download it and check it, rather than trusting
  the pipeline that produced it.
- Treat "the pipeline passed" and "the thing shipped" as **separate claims requiring separate
  evidence**, in the same way a local test receipt and a CI green are separate.
- Before any release, check the credentials are still present. Their absence is invisible until
  precisely the moment they are needed.
