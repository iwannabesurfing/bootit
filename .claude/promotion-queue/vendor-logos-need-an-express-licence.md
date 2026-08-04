---
slug: vendor-logos-need-an-express-licence
origin: BootIt
session: bootit-v3.1.0-release-ui-redesign
date: 2026-08-01
target: spine
relevance: all — any LEME product whose UI, marketing site or store listing references a third-party platform or vendor
status: pending
reliability-target: L4
gate: fdd-field
hook: Integrating with a vendor grants no right to their logo. Their NAME as text is usually fine (nominative use); their MARK almost never is — and the distinction is stated on the vendor's own trademark page, so it takes two minutes to check.
---

## The lesson

A UI mockup for BootIt put Microsoft's four-pane Windows logo on a platform-selection card.
The instinct defending it was reasonable: *"we download from Microsoft's own servers and
link to their site — surely we can show their logo."*

Legitimacy of the integration is not the test. Microsoft's published guidance draws the line
explicitly, and it is not subtle:

> "our logos, app and product icons, illustrations, photographs, videos, and designs **can
> never be used without an express license**"

versus what is permitted:

> "Truthfully and accurately refer to Microsoft and its products and services"

So **"Windows" as text is allowed** — and downloading from Microsoft's own servers makes
that reference maximally truthful. The **logo is withheld by default**, and the same clause
covers "app and product icons", closing the obvious loophole.

## Why it is worth two minutes even for a free tool

The realistic downside is not litigation over a 3 MB utility. It is a trademark takedown on
the repo, a cease-and-desist, or a store rejection — plus the reputational read. For work
that functions as a public sample of engineering judgement, shipping an unlicensed vendor
mark in a signed, notarised app says *didn't know*, which is worse than plain.

There is usually a design argument pointing the same way. In this case the card already said
**Windows** in large text directly beneath the logo, so the mark carried no information; and
pairing two different companies' real brand marks side by side is exactly the composition
that starts to imply endorsement rather than description. One consistent icon language read
as more deliberate, not less.

## How to apply

- Vendor **name in text**: generally fine when truthful and non-endorsing.
- Vendor **logo / product icon**: assume no, until their trademark page says otherwise.
- Check the vendor's own page — Microsoft, Apple, Google each publish one; do not reason
  from what competitor apps appear to get away with, which may simply be unenforced.
- Apple's SF Symbols licence restricts Apple-branded symbols (e.g. `apple.logo`) too —
  treat those as the same class rather than as free because they ship in the SDK.
- Not legal advice; for anything commercial or store-bound, get a real opinion.
