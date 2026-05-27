# BootIt

A clean, native macOS app (SwiftUI, in [`mac/`](mac/)) that makes **bootable USB
installers for Windows *and* macOS** — no Boot Camp, no Windows PC, no Terminal.

You pick a platform, choose a source (download from the vendor, or use a file
you already have), pick a USB drive, and it writes a fully bootable installer.

The app is a small, signed `.app` (~2.5 MB) and **self-contained**: it bundles a
universal `wimlib` for Windows 11, and uses Apple's own `createinstallmedia` for
macOS. Recipients need nothing else installed.

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

Requires **Xcode** (or Command Line Tools) on macOS 13 Ventura or later.
For the Windows-11 path, install `wimlib` once on the **build** machine as the
source to vendor from: `brew install wimlib`.

```bash
cd mac
./build.sh            # universal (Apple Silicon + Intel)
# or: ./build.sh --native   # this Mac's architecture only (faster)
```

Output: `mac/dist/BootIt.app`

```bash
open "dist/BootIt.app"            # test it
cp -R "dist/BootIt.app" /Applications/   # install
```

`build.sh` runs `vendor-wimlib.sh`, which bundles a **universal** `wimlib` into
`Contents/Resources/wimlib/` (re-pathed to load relative to the app and signed).

### Tests & linting

```bash
cd mac
swift test                 # unit tests — deterministic, no network or USB
swiftlint lint --strict    # style + correctness lint (CI enforces this)
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `swift build`,
`swift test`, and SwiftLint strict on every push and pull request.

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
| 2 | `diskutil eraseDisk` | Format the USB as Mac OS Extended (Journaled) + GPT |
| 3 | `createinstallmedia` | Erase + write the installer **(asks for your admin password)** |

The macOS step needs administrator rights — the app uses the standard system
password prompt; it does not store or handle your password.

---

## Distributing to other Mac users

The app is unsigned (it's free — sharing the app is the same as sharing the
repo), so Gatekeeper blocks the first launch. Recipients do this **once**:

> System Settings → Privacy & Security → **Open Anyway**

(macOS Sequoia 15+ removed the old right-click → Open shortcut for unsigned
apps, so the Open Anyway button in Settings is now the only path.)

```bash
cd mac
ditto -c -k --keepParent "dist/BootIt.app" "BootIt.zip"
```

### Optional: sign + notarise (removes the Gatekeeper warning)

```bash
codesign --deep --force --options runtime \
  --sign "Developer ID Application: YOUR NAME (TEAM_ID)" \
  "dist/BootIt.app"

xcrun notarytool submit "BootIt.zip" \
  --apple-id you@example.com --team-id TEAM_ID \
  --password APP_SPECIFIC_PASSWORD --wait
xcrun stapler staple "dist/BootIt.app"
```

---

## Heads-up: Microsoft rate-limits downloads

Microsoft's download-link endpoint is rate-limited **per IP**. After a few
requests in a short window it returns an anti-bot rejection, which the app
reports clearly. Wait ~10–15 min (or turn off any VPN), or use **Use an existing
ISO file** — that path always works.

---

## Roadmap

- A code-signed, notarised release build (drops the right-click-to-open step)
- App icon

---

## Disclaimer

Downloads Windows and macOS directly from Microsoft's and Apple's official
servers. You must hold a valid licence to use the media. Not affiliated with or
endorsed by Microsoft or Apple.
