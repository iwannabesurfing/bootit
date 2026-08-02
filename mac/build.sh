#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Builds BootIt.app (native SwiftUI, macOS 13+)
#
# Usage:
#   chmod +x build.sh
#   ./build.sh            # universal (arm64 + x86_64) release build
#   ./build.sh --native   # build only for this Mac's architecture (faster)
#
# Output:
#   dist/BootIt.app
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BootIt"
BIN_NAME="BootIt"
BUNDLE_ID="au.media.bootit"
HELPER_NAME="BootItHelper"
HELPER_ID="au.media.bootit.helper"
HELPER_PLIST="au.media.bootit.helper.plist"

echo "╔══════════════════════════════════════════════════╗"
echo "║   BootIt — macOS App Builder                     ║"
echo "╚══════════════════════════════════════════════════╝"

if ! command -v swift &>/dev/null; then
    echo "❌  Swift toolchain not found. Install Xcode or the Command Line Tools."
    exit 1
fi
echo "✅  $(swift --version 2>/dev/null | head -1)"

# ── Build ──────────────────────────────────────────────────────────────────
# Apple Silicon only, deliberately: Intel Macs already have Boot Camp Assistant,
# which is exactly what this app replaces. See "Why Apple Silicon only" in the
# README before making this universal again.
ARCH_ARGS="--arch arm64"

if [[ "${1:-}" == "--native" ]]; then
    echo "ℹ️  --native is no longer needed — builds are arm64-only."
fi

echo ""
echo "🔨  Compiling (release, arm64)…"
if ! swift build -c release $ARCH_ARGS 2>/tmp/bootit_build.log; then
    tail -20 /tmp/bootit_build.log
    echo "❌  Build failed."
    exit 1
fi

BIN_DIR="$(swift build -c release $ARCH_ARGS --show-bin-path)"
BIN_PATH="$BIN_DIR/$BIN_NAME"
HELPER_PATH="$BIN_DIR/$HELPER_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "❌  Built binary not found at $BIN_PATH"
    exit 1
fi
if [[ ! -f "$HELPER_PATH" ]]; then
    echo "❌  Privileged helper not found at $HELPER_PATH"
    exit 1
fi

# ── Assemble the .app bundle ─────────────────────────────────────────────────
echo "📦  Assembling app bundle…"
APP_DIR="dist/${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" \
         "$APP_DIR/Contents/Library/LaunchDaemons"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# ── Embed the privileged helper ──────────────────────────────────────────────
# SMAppService looks for the LaunchDaemon plist at this exact path inside the
# bundle, and its BundleProgram points back at Contents/MacOS/. Get either wrong
# and registration fails with a generic error rather than saying what is missing.
echo "🛡️  Embedding privileged helper…"
cp "$HELPER_PATH" "$APP_DIR/Contents/MacOS/$HELPER_NAME"
cp "$HELPER_PLIST" "$APP_DIR/Contents/Library/LaunchDaemons/$HELPER_PLIST"
plutil -lint "$APP_DIR/Contents/Library/LaunchDaemons/$HELPER_PLIST" >/dev/null

# ── Bundle wimlib so the app is self-contained (no Homebrew for users) ───────
echo ""
echo "🧩  Vendoring wimlib…"
if ./vendor-wimlib.sh; then
    mkdir -p "$APP_DIR/Contents/Resources/wimlib"
    cp vendor/wimlib/* "$APP_DIR/Contents/Resources/wimlib/"
    chmod +x "$APP_DIR/Contents/Resources/wimlib/wimlib-imagex"
else
    echo "⚠️  Could not vendor wimlib — Windows 11 will need a Homebrew wimlib on the user's Mac."
fi

# ── Code sign (inner Mach-O first, then seal the app) ────────────────────────
# BOOTIT_SIGN_ID = a "Developer ID Application: …" identity → real signature with
# the hardened runtime and a secure timestamp, which is what notarisation needs.
# Unset → ad-hoc, which runs locally but leaves Gatekeeper blocking other Macs.
SIGN_ID="${BOOTIT_SIGN_ID:-}"
WIMDIR="$APP_DIR/Contents/Resources/wimlib"

if [[ -n "$SIGN_ID" ]]; then
    echo "🔏  Signing with: $SIGN_ID"
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_ID")
else
    echo "🔏  Ad-hoc code signing (set BOOTIT_SIGN_ID for a Developer ID build)…"
    SIGN_ARGS=(--force --sign -)
fi

sign_one() {   # a failed Developer ID signature is fatal; a failed ad-hoc one isn't
    if [[ -n "$SIGN_ID" ]]; then
        codesign "${SIGN_ARGS[@]}" "$1"
    else
        codesign "${SIGN_ARGS[@]}" "$1" 2>/dev/null || \
            echo "   (codesign skipped for $(basename "$1") — app will still run)"
    fi
}

if [[ -d "$WIMDIR" ]]; then
    for f in "$WIMDIR"/libwim.*.dylib "$WIMDIR/wimlib-imagex"; do
        [[ -f "$f" ]] && sign_one "$f"
    done
fi

# The helper is a bare Mach-O, so its code-signing identifier does not come from
# an Info.plist — it has to be set explicitly. HelperInfo.helperRequirement pins
# exactly this string, so the app refuses to talk to a daemon signed under any
# other identity.
HELPER_BIN="$APP_DIR/Contents/MacOS/$HELPER_NAME"
if [[ -n "$SIGN_ID" ]]; then
    echo "🔏  Signing helper as $HELPER_ID"
    codesign --force --options runtime --timestamp \
             --identifier "$HELPER_ID" --sign "$SIGN_ID" "$HELPER_BIN"
else
    codesign --force --identifier "$HELPER_ID" --sign - "$HELPER_BIN" 2>/dev/null || \
        echo "   (codesign skipped for $HELPER_NAME)"
fi

sign_one "$APP_DIR"

if [[ -n "$SIGN_ID" ]]; then
    codesign --verify --strict --verbose=1 "$APP_DIR"
    codesign --verify --strict --verbose=1 "$HELPER_BIN"

    # SMAppService will not register a daemon whose signature does not satisfy
    # what the app expects at runtime. Failing here is far cheaper than a build
    # that ships and then silently refuses to install its own helper.
    TEAM_ID="$(codesign -dv --verbose=2 "$APP_DIR" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    EXPECTED_TEAM="$(sed -n 's/.*teamIdentifier = "\(.*\)".*/\1/p' Sources/BootItShared/HelperProtocol.swift)"
    if [[ -n "$EXPECTED_TEAM" && "$TEAM_ID" != "$EXPECTED_TEAM" ]]; then
        echo "❌  Signed with team '$TEAM_ID' but HelperInfo pins '$EXPECTED_TEAM'."
        echo "    The app and its helper would refuse to talk to each other."
        exit 1
    fi
    codesign --verify -R="$(printf 'anchor apple generic and identifier "%s" and certificate leaf[subject.OU] = "%s"' \
        "$HELPER_ID" "$EXPECTED_TEAM")" "$HELPER_BIN" \
        && echo "   Helper satisfies the requirement the app enforces."

    echo "   Signature verified. (spctl will still reject it until it's notarised —"
    echo "    run ./package.sh with BOOTIT_NOTARY_PROFILE set.)"
else
    echo ""
    echo "⚠️  Ad-hoc signed: SMAppService will REFUSE to register the privileged"
    echo "   helper, so the macOS path cannot work in this build. Set BOOTIT_SIGN_ID"
    echo "   and run the app from /Applications to exercise it."
fi

SIZE=$(du -sh "$APP_DIR" | awk '{print $1}')
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅  Build successful!                           ║"
echo "╠══════════════════════════════════════════════════╣"
printf "║   Output : %-38s║\n" "$APP_DIR"
printf "║   Size   : %-38s║\n" "$SIZE"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  • Test:        open \"$APP_DIR\""
echo "  • Install:     cp -R \"$APP_DIR\" /Applications/"
echo "  • Distribute:  ./package.sh          # builds dist/${APP_NAME}.dmg"
echo ""
if [[ -z "$SIGN_ID" ]]; then
    echo "⚠️  Ad-hoc signed — on other Macs recipients open it once via:"
    echo "   System Settings → Privacy & Security → Open Anyway"
    echo "   (macOS 15+ removed the old right-click → Open shortcut.)"
fi
