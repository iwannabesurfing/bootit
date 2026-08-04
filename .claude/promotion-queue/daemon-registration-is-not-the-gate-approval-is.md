---
slug: daemon-registration-is-not-the-gate-approval-is
origin: BootIt
session: bootit-2026-08-05-admin-gate-and-previews
date: 2026-08-05
target: profile:swift
relevance: any macOS app registering a LaunchDaemon through SMAppService, i.e. anything needing root for one operation
status: pending
reliability-target: L2
gate: test:mac/Tests/BootItTests/AdminRightsTests.swift
hook: `SMAppService.daemon(...).register()` succeeds for a standard user and returns no error worth acting on — it just parks the service in `.requiresApproval`. The gate is the APPROVAL, and Apple's header says only an admin can give it. An app that asks "did registration fail?" concludes everything is fine for a user who can never finish.
---

## The lesson

Apple states it plainly, in `SMAppService.h`'s discussion for `registerAndReturnError`:

> If the service corresponds to a LaunchDaemon, the LaunchDaemon will not be bootstrapped
> until **an admin** approves the LaunchDaemon in System Settings.

So the question "is registration admin-gated?" has a misleading answer — **no** — and the
question that matters has a different one. Registration succeeds for anybody. The service
moves to `.requiresApproval`. Then a standard account meets a System Settings switch it
cannot complete, and nothing in the API surfaced that.

BootIt's copy said *"BootIt needs **your** approval"* in three places, naming nothing the
user would have to go and find. A standard account would have hit that wall **after a
~14 GB download**, because the registration call sits after the download in the pipeline.

## What to do about it

Read whether the current account is an administrator and say so *before* the expensive or
destructive part. It is `admin` group membership — `/etc/group` ships `admin:*:80:root`,
and the Users & Groups "allow this user to administer" checkbox is exactly that membership:

```swift
guard let group = getgrnam("admin"), let pw = getpwnam(user) else { return nil }
// getgrouplist reports the size it needs even when it returns -1; retry at that size.
// Reading the truncated list is how an admin with many memberships reads as a standard user.
```

Return **nil for "could not establish", never false**. A failed reading rendered as a
warning tells administrators to go and find an administrator.

## This did not need the test account it was scheduled for

It sat open four sessions as "~5 minutes on a test account". It needed neither:

- The **rule** is in a header on disk. No experiment can outrank Apple stating it.
- The **reading** is checkable against accounts every macOS install ships — `nobody` and
  `daemon` are not administrators, `root` is. Both directions pinned, on any machine and on
  CI, with nobody creating a login.

A second account would only settle the remaining UI question: whether System Settings offers
a standard user an authentication sheet an admin could fill in beside them. Because that is
unknown, **warn — do not block**. Refusing to start would claim an answer the documentation
does not give.

## Applies when

Any privileged-helper design, and any moment a feature's viability for non-admin users is
assumed rather than checked. Note the asymmetry worth stating in the UI: an unprivileged
path in the same app (BootIt's Windows writer) may work fine for a standard account, so the
honest message is scoped to the feature, not the app.
