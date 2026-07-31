#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# vendor-wimlib.sh — Produce a self-contained arm64 wimlib in vendor/wimlib/
# that loads relative to its own binary (@executable_path), so it can be dropped
# into the .app and run with no Homebrew on the user's machine.
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

rm -rf "$OUT"
mkdir -p "$OUT"

echo "📥  wimlib: $PREFIX"
cp "$NATIVE_BIN" "$OUT/wimlib-imagex"
cp "$NATIVE_LIB" "$OUT/$LIBNAME"
chmod +x "$OUT/wimlib-imagex" "$OUT/$LIBNAME"

# BootIt is arm64-only, so the vendored copy has to be too. An x86_64 wimlib
# here would build cleanly and then fail to launch on every user's Mac.
ARCHS="$(lipo -archs "$OUT/wimlib-imagex")"
if [[ "$ARCHS" != *arm64* ]]; then
    echo "❌  Homebrew's wimlib is '$ARCHS', not arm64 — build on an Apple Silicon Mac."
    exit 1
fi

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
