#!/bin/bash
set -euo pipefail

# Ensure bare `swiftc` can locate the macOS SDK even in a non-interactive shell
# (interactive logins resolve it via the default toolchain, but cron / CI / agent
# shells may not — without this, compiling `import Cocoa` fails with "no such
# module 'Cocoa'"). Only fills SDKROOT when unset, so an explicit override wins.
: "${SDKROOT:=$(xcrun --show-sdk-path --sdk macosx)}"
export SDKROOT
if [ -z "${CLANG_MODULE_CACHE_PATH:-}" ] && [ ! -w "${HOME}/Library/Caches" ]; then
    export CLANG_MODULE_CACHE_PATH="/tmp/agymonitor-clang-module-cache"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AGYMonitor"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="$SCRIPT_DIR/dist"
DMG_NAME="$APP_NAME.dmg"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Info.plist")

SKIP_DMG=0
for arg in "$@"; do
    if [ "$arg" = "--skip-dmg" ]; then
        SKIP_DMG=1
    fi
done

echo "🔨 Building $APP_NAME v$VERSION..."

# ── Step 1: Compile Swift (Universal Binary: arm64 + x86_64) ──
echo "  [1/4] Compiling Swift (universal binary)..."
mkdir -p "$BUILD_DIR"
swiftc "$SCRIPT_DIR/Sources/"*.swift \
    -o "$BUILD_DIR/${APP_NAME}_arm64" \
    -framework Cocoa \
    -framework Security \
    -lsqlite3 \
    -O \
    -target arm64-apple-macosx13.0
swiftc "$SCRIPT_DIR/Sources/"*.swift \
    -o "$BUILD_DIR/${APP_NAME}_x86_64" \
    -framework Cocoa \
    -framework Security \
    -lsqlite3 \
    -O \
    -target x86_64-apple-macosx13.0
lipo -create \
    "$BUILD_DIR/${APP_NAME}_arm64" \
    "$BUILD_DIR/${APP_NAME}_x86_64" \
    -output "$BUILD_DIR/$APP_NAME"
rm -f "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

echo "  ✅ Compiled (universal: arm64 + x86_64)"

# ── Step 1.5: Generate app icon ──
echo "  [1.5/4] Generating app icon..."
swiftc "$SCRIPT_DIR/generate_icon.swift" "$SCRIPT_DIR/Sources/AGYLogo.swift" \
    -framework Cocoa -framework ImageIO \
    -o "$BUILD_DIR/generate_icon"
# Icon generator only runs once at build time on the build machine — host arch
# (swiftc default) is always correct, no -target / universal binary needed.
"$BUILD_DIR/generate_icon" "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/AppIcon.icns"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns" 2>/dev/null || [ -s "$BUILD_DIR/AppIcon.icns" ]
echo "  ✅ Icon generated"

# ── Step 2: Create .app bundle ──
echo "  [2/4] Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME"   "$APP_BUNDLE/Contents/MacOS/"
cp "$SCRIPT_DIR/Info.plist"  "$APP_BUNDLE/Contents/"
cp "$BUILD_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Bundle & syntax-check the local usage analysis script
REPO_SCRIPT="$SCRIPT_DIR/Resources/analyze_usage.py"
if [ ! -f "$REPO_SCRIPT" ]; then
    echo "  ❌ ERROR: Required script not found: $REPO_SCRIPT"
    exit 1
fi
if python3 -m py_compile "$REPO_SCRIPT"; then
    echo "  ✅ analyze_usage.py syntax OK (py_compile)"
else
    echo "  ❌ ERROR: analyze_usage.py failed py_compile: $REPO_SCRIPT"
    exit 1
fi
cp "$REPO_SCRIPT" "$APP_BUNDLE/Contents/Resources/"
chmod +x "$APP_BUNDLE/Contents/Resources/analyze_usage.py"
echo "  ✅ Bundled analyze_usage.py"

# Code sign. Prefer a stable self-signed identity so every rebuild keeps a CONSTANT
# code identity (cert-based Designated Requirement). Run setup_signing.sh once to
# create the identity; falls back to ad-hoc `-` when absent (e.g. CI).
SIGN_IDENTITY="AGYMonitor Self-Signed"
SIGNED=0
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    if SIGN_OUT="$(codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>&1)"; then
        echo "  ✅ Signed with stable identity ($SIGN_IDENTITY)"
        SIGNED=1
    else
        echo "  ⚠️  Signing with stable identity failed, falling back to ad-hoc. codesign said:"
        printf '%s\n' "$SIGN_OUT" | sed 's/^/       /'
    fi
fi
if [ "$SIGNED" = "0" ]; then
    if SIGN_OUT="$(codesign --force --sign - "$APP_BUNDLE" 2>&1)"; then
        echo "  ✅ Ad-hoc signed (run setup_signing.sh for a stable identity)"
        SIGNED=1
    else
        echo "  ❌ ERROR: ad-hoc signing failed. codesign said:"
        printf '%s\n' "$SIGN_OUT" | sed 's/^/       /'
        exit 1
    fi
fi

# Verify the signature — a broken/partial signature must fail the build, not ship.
if VERIFY_OUT="$(codesign --verify --deep --strict "$APP_BUNDLE" 2>&1)"; then
    echo "  ✅ Signature verified (codesign --verify --deep --strict)"
else
    echo "  ❌ ERROR: code signature verification failed:"
    printf '%s\n' "$VERIFY_OUT" | sed 's/^/       /'
    exit 1
fi

echo "  ✅ Bundle ready: $APP_BUNDLE"

# ── Step 3: Create DMG ──
echo "  [3/4] Creating DMG..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/README.txt" << EOF
AGY Monitor v$VERSION
=====================

Monitor your Google Antigravity token usage, API-equivalent cost, active time,
live sessions, and plan quota from the macOS menu bar or display notch.

Installation:
  1. Drag AGYMonitor.app to Applications
  2. Launch it (first time: right-click > Open to bypass Gatekeeper)
  3. Done! The Antigravity icon appears in your menu bar

Requirements:
  - macOS 13+ (Intel & Apple Silicon)
  - Python 3 (included with macOS / Xcode Command Line Tools)
  - Google Antigravity CLI, Desktop, or IDE (data in ~/.gemini/)

Features:
  - Cost & Tokens dual view with per-model breakdown (Carbon / Argon / Neon / Hydrogen / Flash / Claude / Other)
  - Today / This Week / This Month summary cards + daily stacked chart
  - Active Time view (Week timeline, Month timeline, GitHub-style Year heatmap)
  - Live Antigravity sessions grouped by workspace with click-to-jump
  - Plan quota & AI Credits remaining windows with reset countdowns
  - Optional Notch display mode (⋯ menu > Display location > Notch)
  - Durable local archive surviving transcript cleanup
  - Multi-language: English, 简体中文, 繁體中文, 日本語
  - No Dock icon — lives purely in the menu bar or notch

Data source:
  Reads local Antigravity transcripts & metadata under ~/.gemini/
  Pricing fetched from LiteLLM (cached 24h) + AGY fallback rate table
  All local session data stays on your machine.
EOF

if [ "$SKIP_DMG" = "1" ]; then
    echo "  ⏭️  Skipping hdiutil DMG creation (--skip-dmg)"
else
    rm -f "$DIST_DIR/$DMG_NAME"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$STAGING" \
        -ov \
        -format UDZO \
        "$DIST_DIR/$DMG_NAME"

    echo "  ✅ DMG created"
fi

# ── Step 4: Summary ──
echo ""
echo "========================================="
echo "✅ Build complete!"
echo ""
echo "  App:  $APP_BUNDLE"
echo "  DMG:  $DIST_DIR/$DMG_NAME"
echo ""
echo "  To run now:  open \"$APP_BUNDLE\""
echo "  To share:    send $DIST_DIR/$DMG_NAME"
echo "========================================="
