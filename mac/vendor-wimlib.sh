#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# vendor-wimlib.sh — Produce a self-contained, ideally universal wimlib in
# vendor/wimlib/ that loads relative to its own binary (@executable_path), so it
# can be dropped into the .app and run with no Homebrew on the user's machine.
#
# Output: vendor/wimlib/{wimlib-imagex, libwim.<n>.dylib}
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

OUT="vendor/wimlib"

if ! command -v brew &>/dev/null; then
    echo "❌  Homebrew not found — needed once to source the wimlib binaries."
    echo "    Install it from https://brew.sh, then: brew install wimlib"
    exit 1
fi

PREFIX="$(brew --prefix wimlib 2>/dev/null || true)"
if [[ -z "$PREFIX" || ! -x "$PREFIX/bin/wimlib-imagex" ]]; then
    echo "❌  wimlib not installed. Run:  brew install wimlib"
    exit 1
fi

NATIVE_BIN="$PREFIX/bin/wimlib-imagex"
# Derive the exact dylib name the binary references (e.g. libwim.15.dylib).
LIBNAME="$(basename "$(otool -L "$NATIVE_BIN" | awk '/libwim/{print $1; exit}')")"
NATIVE_LIB="$PREFIX/lib/$LIBNAME"
HOSTARCH="$(uname -m)"
OTHERARCH=$([[ "$HOSTARCH" == "arm64" ]] && echo x86_64 || echo arm64)

rm -rf "$OUT" vendor/.other
mkdir -p "$OUT"

echo "📥  Native wimlib ($HOSTARCH): $PREFIX"

# ── Try to obtain the other architecture for a universal binary ──────────────
OTHER_BIN=""; OTHER_LIB=""
for CODENAME in tahoe sequoia sonoma ventura; do
    TAG="${OTHERARCH}_${CODENAME}"
    if brew fetch --force --bottle-tag="$TAG" wimlib >/dev/null 2>&1; then
        CACHE="$(brew --cache --bottle-tag="$TAG" wimlib 2>/dev/null || true)"
        if [[ -f "$CACHE" ]]; then
            mkdir -p vendor/.other
            tar -xzf "$CACHE" -C vendor/.other 2>/dev/null || continue
            OTHER_BIN="$(find vendor/.other -name wimlib-imagex 2>/dev/null | head -1)"
            OTHER_LIB="$(find vendor/.other -name "$LIBNAME" 2>/dev/null | head -1)"
            [[ -n "$OTHER_BIN" && -n "$OTHER_LIB" ]] && break
        fi
    fi
done

if [[ -n "$OTHER_BIN" && -n "$OTHER_LIB" ]]; then
    echo "🔗  Building universal wimlib ($HOSTARCH + $OTHERARCH)…"
    lipo -create "$NATIVE_BIN" "$OTHER_BIN" -output "$OUT/wimlib-imagex"
    lipo -create "$NATIVE_LIB" "$OTHER_LIB" -output "$OUT/$LIBNAME"
else
    echo "⚠️  Could not fetch the $OTHERARCH build — bundling $HOSTARCH only."
    echo "    (App will be self-contained on $HOSTARCH Macs; the other arch would need brew.)"
    cp "$NATIVE_BIN" "$OUT/wimlib-imagex"
    cp "$NATIVE_LIB" "$OUT/$LIBNAME"
fi
rm -rf vendor/.other
chmod +x "$OUT/wimlib-imagex" "$OUT/$LIBNAME"

# ── Re-path so the binary loads the dylib sitting next to it ─────────────────
install_name_tool -id "@executable_path/$LIBNAME" "$OUT/$LIBNAME"
for OLD in $({ otool -arch arm64 -L "$OUT/wimlib-imagex" 2>/dev/null
               otool -arch x86_64 -L "$OUT/wimlib-imagex" 2>/dev/null
               otool -L "$OUT/wimlib-imagex" 2>/dev/null; } | awk '/libwim/{print $1}' | sort -u); do
    install_name_tool -change "$OLD" "@executable_path/$LIBNAME" "$OUT/wimlib-imagex" 2>/dev/null || true
done

# ── Ad-hoc sign (install_name_tool invalidated the originals) ────────────────
codesign --force --sign - "$OUT/$LIBNAME"
codesign --force --sign - "$OUT/wimlib-imagex"

# ── Verify it actually runs detached from Homebrew ───────────────────────────
if VER="$("$OUT/wimlib-imagex" --version 2>&1 | head -1)"; then
    echo "✅  Vendored: $VER"
    echo "    arch: $(lipo -info "$OUT/wimlib-imagex" | sed 's/.*: //')"
else
    echo "❌  Vendored wimlib failed to run."
    exit 1
fi
