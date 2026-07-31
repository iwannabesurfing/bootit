#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# package.sh — Wraps dist/BootIt.app into the distributable dist/BootIt.dmg,
# notarising and stapling it when credentials are available.
#
# Usage:
#   ./build.sh && ./package.sh
#
# Environment (all optional — with none of it set you get an ad-hoc DMG that
# still works, but Gatekeeper will warn on other Macs):
#
#   BOOTIT_SIGN_ID          "Developer ID Application: NAME (TEAMID)"
#                           Must match the identity build.sh signed the app with.
#
#   BOOTIT_NOTARY_PROFILE   A keychain profile made by:
#                             xcrun notarytool store-credentials …
#   …or an App Store Connect API key (what CI uses — no app-specific password):
#   BOOTIT_NOTARY_KEY       Path to the AuthKey_XXXXXXXX.p8 file
#   BOOTIT_NOTARY_KEY_ID    The key ID (the XXXXXXXX in that filename)
#   BOOTIT_NOTARY_ISSUER    The issuer UUID from App Store Connect
#   …or an Apple ID and app-specific password:
#   BOOTIT_NOTARY_APPLE_ID  Apple ID
#   BOOTIT_NOTARY_TEAM_ID   Team ID
#   BOOTIT_NOTARY_PASSWORD  App-specific password
#
# Output:
#   dist/BootIt.dmg
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BootIt"
APP_DIR="dist/${APP_NAME}.app"
DMG="dist/${APP_NAME}.dmg"
ZIP="dist/${APP_NAME}-notarize.zip"

SIGN_ID="${BOOTIT_SIGN_ID:-}"

echo "╔══════════════════════════════════════════════════╗"
echo "║   BootIt — Packager                              ║"
echo "╚══════════════════════════════════════════════════╝"

if [[ ! -d "$APP_DIR" ]]; then
    echo "❌  $APP_DIR not found. Run ./build.sh first."
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
echo "📦  Packaging ${APP_NAME} ${VERSION}"

# ── Refuse to ship something that won't launch on a user's Mac ───────────────
# BootIt is arm64-only by design (Intel Macs already have Boot Camp Assistant),
# so every Mach-O in the bundle must contain arm64. An x86_64-only wimlib would
# build and package cleanly here and then fail on every user's machine.
check_arm64() {   # $1 = label, $2 = Mach-O path
    [[ -f "$2" ]] || return 0
    local arches; arches="$(lipo -archs "$2" 2>/dev/null || echo "")"
    if [[ "$arches" != *arm64* ]]; then
        echo "❌  $1 is not arm64 (${arches:-unknown})."
        return 1
    fi
    echo "   $1: $arches ✓"
    return 0
}

echo "🔬  Checking architectures…"
BAD=false
check_arm64 "app binary" "$APP_DIR/Contents/MacOS/${APP_NAME}" || BAD=true
for w in "$APP_DIR"/Contents/Resources/wimlib/wimlib-imagex \
         "$APP_DIR"/Contents/Resources/wimlib/libwim.*.dylib; do
    check_arm64 "$(basename "$w")" "$w" || BAD=true
done

if [[ "$BAD" == true ]]; then
    echo ""
    echo "   Build BootIt on an Apple Silicon Mac (see README.md)."
    exit 1
fi

# ── Work out how (or whether) we can talk to the notary service ──────────────
NOTARY_ARGS=()
if [[ -n "${BOOTIT_NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$BOOTIT_NOTARY_PROFILE")
elif [[ -n "${BOOTIT_NOTARY_KEY:-}" && -n "${BOOTIT_NOTARY_KEY_ID:-}" && -n "${BOOTIT_NOTARY_ISSUER:-}" ]]; then
    NOTARY_ARGS=(--key "$BOOTIT_NOTARY_KEY"
                 --key-id "$BOOTIT_NOTARY_KEY_ID"
                 --issuer "$BOOTIT_NOTARY_ISSUER")
elif [[ -n "${BOOTIT_NOTARY_APPLE_ID:-}" && -n "${BOOTIT_NOTARY_TEAM_ID:-}" && -n "${BOOTIT_NOTARY_PASSWORD:-}" ]]; then
    NOTARY_ARGS=(--apple-id "$BOOTIT_NOTARY_APPLE_ID"
                 --team-id "$BOOTIT_NOTARY_TEAM_ID"
                 --password "$BOOTIT_NOTARY_PASSWORD")
fi

# Notarisation is only meaningful on a Developer ID signature — the service
# rejects ad-hoc signed code outright, so don't waste an upload on it.
NOTARISE=false
if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
    if [[ -n "$SIGN_ID" ]]; then
        NOTARISE=true
    else
        echo "⚠️  Notary credentials found but BOOTIT_SIGN_ID is unset — skipping"
        echo "    notarisation (the service only accepts Developer ID signatures)."
    fi
fi

notarise() {   # $1 = path to a .zip or .dmg to submit
    xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait
}

# ── Notarise + staple the .app first, so the copy inside the DMG carries its
#    own ticket and validates even offline ────────────────────────────────────
if [[ "$NOTARISE" == true ]]; then
    echo ""
    echo "☁️   Notarising the app (this usually takes 1–5 minutes)…"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    notarise "$ZIP"
    rm -f "$ZIP"
    xcrun stapler staple "$APP_DIR"
    echo "✅  App notarised and stapled."
fi

# ── Build the drag-to-Applications DMG ───────────────────────────────────────
echo ""
echo "💽  Building ${DMG}…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$DMG"

if [[ -n "$SIGN_ID" ]]; then
    echo "🔏  Signing the DMG…"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi

if [[ "$NOTARISE" == true ]]; then
    echo ""
    echo "☁️   Notarising the DMG…"
    notarise "$DMG"
    xcrun stapler staple "$DMG"
    echo "✅  DMG notarised and stapled."
fi

# ── Report what a recipient's Mac will actually make of this ─────────────────
echo ""
echo "🔍  Gatekeeper assessment:"
spctl -a -vv "$APP_DIR" 2>&1 | sed 's/^/    /' || true
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/    /' || true

SIZE=$(du -sh "$DMG" | awk '{print $1}')
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅  Package ready                               ║"
echo "╠══════════════════════════════════════════════════╣"
printf "║   Output : %-38s║\n" "$DMG"
printf "║   Size   : %-38s║\n" "$SIZE"
printf "║   Version: %-38s║\n" "$VERSION"
echo "╚══════════════════════════════════════════════════╝"

if [[ "$NOTARISE" != true ]]; then
    echo ""
    echo "⚠️  Not notarised — recipients must approve it once via"
    echo "   System Settings → Privacy & Security → Open Anyway."
    echo "   Set BOOTIT_SIGN_ID + BOOTIT_NOTARY_PROFILE to remove that step."
fi
