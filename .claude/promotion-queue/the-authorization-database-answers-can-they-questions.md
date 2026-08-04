---
slug: the-authorization-database-answers-can-they-questions
origin: BootIt
session: bootit-2026-08-05-v3.4.0-release
date: 2026-08-05
target: profile:swift
relevance: any macOS app whose feature needs a privileged action, where "can a standard user complete this?" is filed as needing a second account
status: pending
reliability-target: L4
gate: none
gate-detail: a reading method, not a property of this codebase — nothing here compiles or asserts. The output is a sharper question, not a shipped behaviour, and the copy it would change was deliberately left alone.
hook: "Will macOS let a non-admin do this?" reads as a question only a second account can answer. Often the answer is already on the machine — `security authorizationdb read <right>` resolves the rule chain and says whether the right is satisfiable by an ADMIN AUTHENTICATING IN SOMEONE ELSE'S SESSION, which is the actual question behind most of them.
---

## The lesson

macOS's authorization policy is a readable database, not a black box. `security
authorizationdb read <right>` prints the rule, and rules delegate to named rules you can
read in turn. Two fields decide the question people schedule a test account for:

- `class: user` + `group: admin` + `authenticate-user: true` — **a sheet is presented, and
  any member of that group satisfies it.** The session's own owner does not have to be an
  admin. This is the shape that lets an administrator lean over and type.
- `class: user` + `group: admin` with `authenticate-user: false`, or a rule with no
  authenticate leg at all — the right is decided by *who is logged in*, and no sheet helps.

BootIt carried "does a standard user get an auth sheet on the Login Items switch?" as
needing an account. Resolving the right ServiceManagement actually uses took one command:

```
com.apple.ServiceManagement.daemons.modify   →  k-of-n 1 of
  is-root
  entitled-admin-or-authenticate-admin-nonshared  →  k-of-n 1 of
      entitled-admin-nonshared
      authenticate-admin-nonshared   →  class: user, group: admin,
                                        authenticate-user: true, shared: false
                                        "Authenticate as an administrator."
```

So the **right** is satisfiable by an administrator authenticating in a standard user's
session. Corroborating, from the same machine: `LoginItems.appex` links `SFAuthorization`
and carries `performForWindowID:withAuthorization:` — the shape of a UI built to run an
action behind an authorization sheet, not one that greys a switch out.

## What it does not establish, and why that matters

Neither reading names the daemon-approval toggle specifically. The right proves what
*ServiceManagement* requires; the appex proves the settings pane *can* raise a sheet. That
System Settings routes this particular switch through that particular right is inference,
and inference is not observation.

So the honest outcome is **a narrowed question, not a closed one**: the next person with a
standard account observes one thing — sheet or no sheet — instead of exploring. And the
user-facing copy was deliberately **not** changed on the strength of it. Telling a standard
user "an administrator can approve it here, now" on an inferred reading fails in the
confident direction; the existing wording is merely pessimistic, which is the safe one.

## Applies when

Any backlog item of the form "can a non-admin / non-owner / managed-device user complete
this flow?". Read the right before booking the account. Cost is one command; the worst case
is that the rule is `class: rule` over something opaque and you have learned that in ten
seconds. Pairs with [[human-gated-may-mean-unread-not-untestable]] — that lesson says to ask
whether a primary source already answers a human-gated question; this one names a primary
source that answers a whole family of them. Also
[[an-unestablished-reading-is-not-a-negative-one]] and
[[daemon-registration-is-not-the-gate-approval-is]], which this narrows the open tail of.
