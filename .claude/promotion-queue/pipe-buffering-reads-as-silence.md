---
slug: pipe-buffering-reads-as-silence
origin: BootIt
session: bootit-2026-08-05-copy-progress-correction
date: 2026-08-05
target: profile:swift
relevance: any process spawning a CLI and reading its output for live progress — Process/Pipe on Apple platforms, child_process elsewhere; especially Apple's own long-running tools
status: pending
reliability-target: L3
gate: test:mac/Tests/BootItTests/RecordedRunTests.swift
hook: A child's stdout is FULLY buffered when it is a pipe and line-buffered when it is a tty. So a tool that prints live `\r` progress goes silent down a pipe and dumps everything at the end — which reads as "this tool reports no progress" and sends you looking for a different signal. The signature is sequential stage banners arriving microseconds apart.
---

## The lesson

libc chooses stdout's buffering by what stdout *is*. Interactive terminal → line-buffered, so each
`\r` rewrite appears immediately. Pipe → **fully buffered** (typically 4 KB), so output accumulates
in the child's own buffer and is released when the buffer fills, the process flushes, or it exits.

A tool with a `\r`-rewritten progress line writes no newline at all for the duration of a phase, so
a 4 KB buffer may not fill for twenty minutes. From the parent, that is indistinguishable from a
tool that prints nothing.

BootIt spent three shipped attempts, a tri-model gate and a deleted denominator on the premise that
`createinstallmedia` "emits nothing during the copy". It emits
`Copying to disk: 0%… 10%… … 100%`. It arrived at 91% of the run, complete, in one line.

## The signature

Timestamp the lines. From a recorded trace:

```json
{"elapsed":263.99737775,  "line":"Copying essential files..."}
{"elapsed":263.997488875, "line":"Copying the macOS RecoveryOS..."}
{"elapsed":263.997610417, "line":"Making disk bootable..."}
```

Three **sequential** stages, 0.2 ms apart. Stages that logically happen minutes apart cannot arrive
together unless they were held and released together. That is a buffer flush, and it is the cheapest
proof available that the silence is yours, not the tool's — it needs no second run and no
instrumentation beyond timestamping what you already read.

## How to apply

- **Timestamp every line you read from a child process** and look for impossible simultaneity before
  concluding a tool is silent. It costs one field in a trace.
- **Read from a pty, not a pipe**, when you need live progress: allocate with `posix_openpt` /
  `openpty`, hand the child the slave side, read the master. The child then line-buffers.
- **Split on `\r` as well as `\n`.** Necessary and not sufficient — BootIt's reader already did, and
  still saw nothing, because the bytes had not left the child. A correct splitter can hide the real
  cause by making the reader look blameless.
- Note the asymmetry that makes this bite: **it works perfectly when you test it by hand in a
  terminal**, and fails only in the app.

## Applies when

Any long-running CLI wrapped for a GUI or an agent — imagers, installers, `ffmpeg`, `rsync`,
package managers, build tools. Before designing around "this tool reports no progress", confirm the
silence is not one you imposed. Pairs with [[a-stage-banner-marks-a-beginning]] — BootIt reached for
a banner precisely because it believed the percentages did not exist.
