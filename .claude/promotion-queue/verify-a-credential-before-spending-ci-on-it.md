---
slug: verify-a-credential-before-spending-ci-on-it
origin: BootIt
session: bootit-2026-08-03-release
date: 2026-08-03
target: spine
relevance: all — any workflow where a human supplies a certificate, key or credential file for CI to consume
status: pending
reliability-target: L2
hook: Verify a supplied credential LOCALLY before spending a CI run proving it wrong. BootIt's Developer ID certificate arrived first as a `.cer` with no private key, then twice as the wrong identity (Apple Distribution rather than Developer ID Application); `openssl pkcs12 -nokeys` named the identity in under a second each time, where the pipeline would have burned a full macOS build to say the same thing far less clearly.
---

## The lesson

Restoring signing credentials meant asking a human to export a certificate from a GUI keychain and
hand over the file. Three attempts:

1. A **`.cer`** — a certificate with no private key. Cannot sign anything.
2. A **`.p12`**, but containing `Apple Distribution: LEME Digital` — the wrong identity.
3. A **`.p12`** containing `Developer ID Application: LEME Digital` — correct.

Each was checked before use:

```
openssl pkcs12 -in Certificates.p12 -nokeys -passin env:P12PASS | grep friendlyName
```

Under a second, and it prints the identity by name. The wrong ones never reached CI.

Had they, the failure would have arrived ~5 minutes later as a `codesign` error about an identity
not being found in the keychain — accurate, but several layers removed from "you exported the row
above the one you wanted", and on a macOS runner that bills at roughly 10× a Linux one.

Worth noting *why* the human picked wrong twice, because it is not carelessness: the two
certificates share an issuer, a team, an organisation and a display prefix. In the keychain UI they
differ by a few words and an expiry date. This is a mistake the interface invites.

## Why it fails silently

A credential file is opaque. `ls` shows a plausible size; `file` says `data`. Nothing about a wrong
certificate looks wrong until something tries to use it, and the thing that tries to use it is
usually the most expensive, most remote step in the chain.

There is also a verification asymmetry: the person exporting cannot easily see what they exported
(the GUI shows a friendly name that is nearly identical for both), and the agent receiving it will
not see inside it either unless it deliberately looks.

## How to apply

- **Open every supplied credential and print what it actually contains** before storing or
  uploading it. For PKCS#12: `openssl pkcs12 -nokeys` for the identity, `-nocerts` to confirm a
  private key is present. Assert both — a cert without a key is the commonest wrong artefact.
- Check for the specific property the consumer requires, not merely that the file parses. "It is a
  valid p12" and "it is the identity this pipeline names in `SIGN_ID`" are different claims.
- When guiding a human through a GUI export, **name the distinguishing field, not the label** —
  here, the expiry date was the only unambiguous discriminator between two near-identical rows.
- Rehearse with the cheapest mechanism that exercises the real path: a dry run that builds, signs
  and notarises but publishes nothing caught everything a tag would have, without a public failure.
