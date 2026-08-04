# BootIt

A clean, native macOS app (SwiftUI, in [`mac/`](mac/)) that makes **bootable USB
installers for Windows *and* macOS** — no Boot Camp, no Windows PC, no Terminal.

You pick a platform, choose a source (download from the vendor, or use a file
you already have), pick a USB drive, and it writes a fully bootable installer.

The app is a small `.app` (~2.5 MB) and **self-contained**: it bundles `wimlib`
for Windows 11, and uses Apple's own `createinstallmedia` for macOS. Recipients
need nothing else installed.

Requires an **Apple Silicon** Mac on macOS 13 Ventura or later — see
[Why Apple Silicon only](#why-apple-silicon-only).

**[⬇ Download the latest release](https://github.com/iwannabesurfing/bootit/releases/latest/download/BootIt.dmg)** —
see [First launch](#first-launch-gatekeeper) for the one-time Gatekeeper step.

---

## What it does

**Windows** — download a Windows 10/11 ISO from Microsoft (edition + language) or
use a local `.iso`, then write a FAT32/MBR UEFI-bootable USB (splitting
`install.wim` automatically when it's over FAT32's 4 GB limit). Optional toggle:
**bypass the Windows 11 checks** (TPM, Secure Boot, RAM) and show the "I don't
have internet" option during setup — via an `autounattend.xml` written to the
USB root (`LabConfig` bypass keys + `BypassNRO`), the way Rufus does it.

**macOS** — download a macOS installer from Apple (any version `softwareupdate`
offers) or use an "Install macOS …" app already on your Mac, then build the
installer with Apple's `createinstallmedia`.

Both flows fully erase/format the selected USB. The internal drive is never shown.

---

## Build

Requires **Xcode** (or Command Line Tools) on an Apple Silicon Mac running
macOS 13 Ventura or later. For the Windows-11 path, install `wimlib` once on the
**build** machine as the source to vendor from: `brew install wimlib`.

```bash
cd mac
./build.sh
```

Output: `mac/dist/BootIt.app`

```bash
open "dist/BootIt.app"            # test it
cp -R "dist/BootIt.app" /Applications/   # install
```

`build.sh` runs `vendor-wimlib.sh`, which bundles `wimlib` into
`Contents/Resources/wimlib/` (re-pathed to load relative to the app and signed).
`package.sh` refuses to build a DMG unless every binary in the bundle is arm64,
so a wrong-architecture build can't reach users.

### Why Apple Silicon only

Intel Macs ship with **Boot Camp Assistant**, which already creates Windows USB
installers natively. Apple Silicon Macs don't — that gap is the reason this app
exists, so Intel is not a target.

The practical trigger was Homebrew dropping its x86_64 `wimlib` bottle (only
`arm64_tahoe` is published now), which made a universal build impossible without
compiling wimlib from source or adding an Intel CI runner. Releases up to
**v3.0.0** are universal and still work on Intel.

### Tests & linting

```bash
cd mac
swift test                 # unit tests — deterministic, no network or USB
swiftlint lint --strict    # style + correctness lint (CI enforces this)
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `swift build`,
`swift test`, and SwiftLint strict on every push and pull request.

### SwiftUI previews — open the `BootItKit` scheme, not `BootIt-Package`

The app lives in the **`BootItKit` library**; `Sources/BootIt` is a thin `@main`
over it and should stay that way. That split is not decoration. Xcode resolves a
preview host from the selected scheme, and any scheme containing an executable
target makes that executable the host — which cannot carry `ENABLE_PREVIEWS`, so
previews fail with *"the executable target "BootIt" needs the build setting …"*
**even for files in a library target**. All three arrangements were measured on
Xcode 26.6:

| View's target | Scheme | Renders? |
|---|---|---|
| executable | `BootIt-Package` | no |
| library | `BootIt-Package` | no — error still names the executable |
| library | **`BootItKit`** | **yes** |

So: open `mac/Package.swift`, set the destination to **My Mac**, pick the
**`BootItKit`** scheme, and the ~40 `#Preview` fixtures render. They are all
behind `#if DEBUG` and are absent from the release binary.

### Self-test against the live catalogues (no USB needed)

These hit Microsoft's / Apple's servers, so they're manual diagnostics rather
than CI tests (Microsoft rate-limits per IP — see below):

```bash
.build/release/BootIt --selftest windows11   # Microsoft catalogue
.build/release/BootIt --mactest              # macOS installer catalogue
.build/release/BootIt --writetest --split    # USB copy/split/verify on temp dirs
```

---

## How the writing works

**Windows**

| Step | Tool | What happens |
|------|------|--------------|
| 1 | URLSession | Resolve + stream the ISO from Microsoft (or use a local file) |
| 2 | `diskutil eraseDisk` | Format the USB as FAT32 + MBR (UEFI-bootable; MBR avoids the stray EFI partition Windows Setup would otherwise hijack) |
| 3 | `hdiutil attach` | Mount the ISO read-only |
| 4 | FileManager | Copy everything except `install.wim` with byte-level progress |
| 5 | bundled `wimlib` | Copy `install.wim` (≤4 GB) or split it into `.swm` parts (>4 GB) |
| 6 | `mdutil` / `dot_clean` | Disable Spotlight on the drive and strip macOS metadata (`._*`, `.Spotlight-V100`, `.fseventsd`) for a clean, Rufus-style USB |
| 7 | — | Verify `efi/boot/bootx64.efi` is present, then `sync` |

**macOS**

| Step | Tool | What happens |
|------|------|--------------|
| 1 | `softwareupdate` | List/download the installer to /Applications (or use an existing one) |
| 2 | `diskutil eraseDisk` | Format the USB as Mac OS Extended (Journaled) + GPT — run by the helper |
| 3 | `createinstallmedia` | Write the installer — run by the helper |

### The privileged helper, and the one thing you have to allow

`createinstallmedia` is Apple's tool and it has to run as root. BootIt does that
through a small **LaunchDaemon** registered with `SMAppService`, talking to the
app over XPC. Both ends pin each other's code signature, so nothing but a
BootIt signed by this team can ask the daemon to erase a disk. The daemon exits
30 seconds after the app stops talking to it, and **Help → Privileged Helper…**
will remove it entirely.

macOS asks you for two separate things, and they are not the same permission:

| What | When you're asked | If it's missing |
|------|-------------------|-----------------|
| **Allow BootIt in the Background** | Automatically, first run — **but only an administrator can grant it** | The helper never installs |
| **Full Disk Access** | **Never — you have to grant it** | `createinstallmedia` fails with "Operation not permitted" |

**A standard (non-administrator) account cannot complete the macOS path alone.**
Apple's own rule, from `SMAppService.h`: a LaunchDaemon "will not be bootstrapped
until an admin approves [it] in System Settings". Registration itself succeeds for
anyone — it is the approval that is gated. BootIt checks at drive-selection time
and says so *before* you download ~14 GB, rather than at the wall afterwards. The
**Windows path is unaffected**: it writes unprivileged and registers no daemon, so
a standard account can build a Windows stick start to finish.

The second one is the trap. TCC gates writes to removable volumes, and
`createinstallmedia` writes a `.IAPhysicalMedia` cookie to the root of the USB.
A background daemon has no GUI session, so macOS **never prompts it** — it is
denied silently, and the failure surfaces fifteen minutes later as an opaque
`NSCocoaErrorDomain Code=513 / errno 1` at the bless step.

So, once: **System Settings → Privacy & Security → Full Disk Access → +  → BootIt**.

**Help → Privileged Helper… → Test USB Access** performs the exact syscall that
fails and reports which side is blocked — the app or the daemon. They are
governed by different rules and produce an identical `EPERM`, which is precisely
why this is worth measuring instead of guessing. BootIt also probes for the
denial *before* erasing, so a missing grant can never cost you the drive's
contents.

No password prompt, on any run. Nothing is typed into BootIt.

---

## Distributing to other Mac users

```bash
cd mac
./build.sh          # dist/BootIt.app
./package.sh        # dist/BootIt.dmg
```

`package.sh` builds the drag-to-Applications DMG that ships on the
[Releases](https://github.com/iwannabesurfing/bootit/releases) page. It also
signs, notarises and staples when credentials are present — see below.

### First launch (Gatekeeper)

Builds made with the credentials below are **signed and notarised**, so they
open normally with no warning.

A build made without them is ad-hoc signed, and Gatekeeper blocks its first
launch. Recipients then have to do this **once**:

> System Settings → Privacy & Security → **Open Anyway**

(macOS Sequoia 15+ removed the old right-click → Open shortcut, so the Open
Anyway button in Settings is now the only path.)

Releases up to and including **v3.0.0** are ad-hoc signed and need that step.

### Signing + notarising (removes the Gatekeeper warning)

Both scripts pick up signing from the environment; with nothing set they fall
back to ad-hoc and still produce a working app and DMG.

```bash
export BOOTIT_SIGN_ID="Developer ID Application: LEME Digital (MD4M4DL5PP)"
export BOOTIT_NOTARY_PROFILE="bootit-notary"

./build.sh          # Developer ID + hardened runtime + secure timestamp
./package.sh        # notarises and staples the app, then the DMG
```

One-time setup on the signing machine:

```bash
# 1. Create a Developer ID Application certificate (Account Holder only):
#    Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application
#    (or developer.apple.com ▸ Certificates ▸ +)

# 2. Store notarisation credentials in the keychain:
xcrun notarytool store-credentials "bootit-notary" \
  --apple-id you@example.com --team-id MD4M4DL5PP \
  --password APP_SPECIFIC_PASSWORD
```

Verify a finished build:

```bash
spctl -a -vv dist/BootIt.app                                     # accepted, Developer ID
spctl -a -t open --context context:primary-signature -v dist/BootIt.dmg
```

### Releasing

Tagging a version builds and publishes the DMG automatically
([`.github/workflows/release.yml`](.github/workflows/release.yml)):

```bash
git tag v3.4.0 && git push origin v3.4.0
```

The workflow refuses to run if the tag and `mac/Info.plist`'s
`CFBundleShortVersionString` disagree. It publishes **only** when the signing
secrets below exist — without them it still builds and uploads the DMG as a
workflow artifact, but won't publish an unsigned release:

| Secret | What it is |
|--------|------------|
| `MACOS_CERT_P12` | Developer ID Application cert + key, `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | Password used when exporting that `.p12` |
| `MACOS_SIGN_ID` | e.g. `Developer ID Application: LEME Digital (MD4M4DL5PP)` |
| `MACOS_NOTARY_KEY_P8` | App Store Connect API key (`AuthKey_XXXXXXXX.p8`), base64-encoded |
| `MACOS_NOTARY_KEY_ID` | The key ID — the `XXXXXXXX` in that filename |
| `MACOS_NOTARY_ISSUER_ID` | Issuer UUID from App Store Connect ▸ Users and Access ▸ Integrations |

---

## Heads-up: Microsoft rate-limits downloads

Microsoft's download-link endpoint is rate-limited **per IP**. After a few
requests in a short window it returns an anti-bot rejection, which the app
reports clearly. Wait ~10–15 min (or turn off any VPN), or use **Use an existing
ISO file** — that path always works.

---

## Roadmap

Nothing outstanding. Signing, notarisation and tagged releases are all in place
as of v3.1.0; v3.0.0 predates them and still needs the Open Anyway step.

---

## Disclaimer

Downloads Windows and macOS directly from Microsoft's and Apple's official
servers. You must hold a valid licence to use the media. Not affiliated with or
endorsed by Microsoft or Apple.
