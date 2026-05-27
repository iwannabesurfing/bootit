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

echo "╔══════════════════════════════════════════════════╗"
echo "║   BootIt — macOS App Builder                     ║"
echo "╚══════════════════════════════════════════════════╝"

if ! command -v swift &>/dev/null; then
    echo "❌  Swift toolchain not found. Install Xcode or the Command Line Tools."
    exit 1
fi
echo "✅  $(swift --version 2>/dev/null | head -1)"

# ── Build ──────────────────────────────────────────────────────────────────
ARCH_ARGS="--arch arm64 --arch x86_64"
if [[ "${1:-}" == "--native" ]]; then ARCH_ARGS=""; fi

echo ""
echo "🔨  Compiling (release)…"
if ! swift build -c release $ARCH_ARGS 2>/tmp/wmc_build.log; then
    if [[ -n "$ARCH_ARGS" ]]; then
        echo "⚠️  Universal build failed — falling back to native arch."
        cat /tmp/wmc_build.log | tail -5
        ARCH_ARGS=""
        swift build -c release
    else
        cat /tmp/wmc_build.log | tail -20
        echo "❌  Build failed."
        exit 1
    fi
fi

BIN_PATH="$(swift build -c release $ARCH_ARGS --show-bin-path)/$BIN_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "❌  Built binary not found at $BIN_PATH"
    exit 1
fi

# ── Assemble the .app bundle ─────────────────────────────────────────────────
echo "📦  Assembling app bundle…"
APP_DIR="dist/${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

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

# ── Ad-hoc sign (inner Mach-O first, then seal the app) ──────────────────────
echo "🔏  Ad-hoc code signing…"
WIMDIR="$APP_DIR/Contents/Resources/wimlib"
if [[ -d "$WIMDIR" ]]; then
    for f in "$WIMDIR"/libwim.*.dylib "$WIMDIR/wimlib-imagex"; do
        [[ -f "$f" ]] && codesign --force --sign - "$f" 2>/dev/null || true
    done
fi
codesign --force --sign - "$APP_DIR" 2>/dev/null || \
    echo "   (codesign skipped — app will still run)"

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
echo "  • Distribute:  ditto -c -k --keepParent \"$APP_DIR\" \"${APP_NAME}.zip\""
echo ""
echo "⚠️  On other Macs (unsigned app), recipients open it once via:"
echo "   System Settings → Privacy & Security → Open Anyway"
echo "   (macOS 15+ removed the old right-click → Open shortcut for unsigned apps.)"
