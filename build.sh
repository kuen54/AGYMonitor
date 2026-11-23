#!/bin/bash
set -euo pipefail

# Ensure bare `swiftc` can locate the macOS SDK even in a non-interactive shell
# (interactive logins resolve it via the default toolchain, but cron / CI / agent
# shells may not — without this, compiling `import Cocoa` fails with "no such
# module 'Cocoa'"). Only fills SDKROOT when unset, so an explicit override wins.
: "${SDKROOT:=$(xcrun --show-sdk-path --sdk macosx)}"
export SDKROOT
if [ -z "${CLANG_MODULE_CACHE_PATH:-}" ] && [ ! -w "${HOME}/Library/Caches" ]; then
    export CLANG_MODULE_CACHE_PATH="/tmp/agymonitor-clang-module-cache-$(id -u)"
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
    -framework Carbon \
    -framework Security \
    -framework UserNotifications \
    -lsqlite3 \
    -O \
    -target arm64-apple-macosx13.0
swiftc "$SCRIPT_DIR/Sources/"*.swift \
    -o "$BUILD_DIR/${APP_NAME}_x86_64" \
    -framework Cocoa \
    -framework Carbon \
    -framework Security \
    -framework UserNotifications \
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

# Code sign.
# - When CODESIGN_IDENTITY is set (e.g. Developer ID Application for notarized release),
#   sign with hardened runtime + secure timestamp and fail loudly if signing fails.
# - Otherwise prefer a stable local self-signed identity so every rebuild keeps a
#   CONSTANT code identity (cert-based Designated Requirement; run setup_signing.sh once),
#   falling back to ad-hoc `-` when absent (e.g. CI).
SIGN_IDENTITY="AGYMonitor Self-Signed"
SIGNED=0
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    if SIGN_OUT="$(codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE" 2>&1)"; then
        echo "  ✅ Signed with CODESIGN_IDENTITY ($CODESIGN_IDENTITY, hardened runtime)"
        SIGNED=1
    else
        echo "  ❌ ERROR: signing with CODESIGN_IDENTITY ($CODESIGN_IDENTITY) failed. codesign said:"
        printf '%s\n' "$SIGN_OUT" | sed 's/^/       /'
        exit 1
    fi
elif security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
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
trap 'rm -rf "$STAGING"' EXIT
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/README.txt" << EOF
AGYMonitor v$VERSION
====================

Native macOS menu bar & notch telemetry instrument for Google Antigravity
(agy CLI, Antigravity 2.0 Desktop, and Antigravity IDE): API-equivalent cost,
token flow, active coding time, live sessions, Black Box replay, and plan quota.

Installation:
  1. Drag AGYMonitor.app into Applications.
  2. Launch AGYMonitor.app.
  3. First launch on macOS 15 Sequoia+ (for unsigned / ad-hoc builds):
     - If macOS blocks the app, click Done, then open:
       System Settings -> Privacy & Security -> scroll down -> click "Open Anyway"
     - Or remove the quarantine attribute once in Terminal:
       xattr -cr /Applications/AGYMonitor.app
  4. The Antigravity icon appears in your menu bar (or display notch).

Requirements:
  - macOS 13+ (Universal binary: Apple Silicon arm64 & Intel x86_64)
  - Python 3.9+ (included with macOS / Xcode Command Line Tools)
  - Google Antigravity CLI (agy), Desktop, or IDE (data in ~/.gemini/)

Highlights in v$VERSION:
  - 5-Tab Precision Instrument Mode + Classic fallback (Cmd+I) & 7 Studio Themes (Cmd+T):
      * Cost:     Borehole Strata & Topographic Ridge daily elevation
      * Tokens:   Folded Token Stream (model -> channel) & 30-day Density Matrix
      * Time:     24h Polar Chronometer (Week), 30-day Elevation + 24h Diurnal
                  (Month), Marching-Squares Year Contour Field (Year)
      * Sessions: Live Agent Telemetry Radar + Universal 60fps Black Box Replay
                  across Swarm, Dynamic Workflow, Subagent Tree, Battle & Solo
      * Plan:     Dual 270° Orbital Phase Dials with pace vectors + AI Credits
  - Real-time Context Window remaining % & universal Output TPS aggregating main
    sessions plus all CLI/Desktop/IDE/nested/workflow/swarm subagents
  - Archival Specimen Card (Cmd+E, 4:5 & 16:9 @2x PNG), 5-Tab Force Touch haptics,
    harmonic acoustic chimes, and auto-updating Daily Blueprint Contour Wallpaper
  - Notch mode (⋯ -> Display location -> Notch) with Live Activity Wing & TPS pill
  - Engineered for 0% busy CPU & ~52 MB footprint (native Darwin libproc, GPU
    Core Animation busy logo, compact closed Notch backing)
  - Durable local monthly archive, built-in update checker, 4 languages
    (English, 简体中文, 繁體中文, 日本語), no Dock icon (LSUIElement=true)

Keyboard Shortcuts:
  Option+Shift+A     Global toggle (Menu Bar panel or Notch, zero Accessibility prompts)
  Cmd+1 .. Cmd+5     Jump to Cost / Tokens / Time / Sessions / Plan tab
  Cmd+[ / Cmd+]      Previous / Next month (or year in Time -> Year)
  Cmd+R              Force refresh usage, active time, and plan quota
  Cmd+T              Cycle through the 7 Studio Themes
  Cmd+I              Toggle Instrument / Classic visualization mode
  Cmd+E              Open Archival Specimen Card preview & exporter
  Esc                Close panel or Specimen Card window
  Up / Down + Return Navigate live sessions & jump to terminal/IDE pane
  Space / Left / Right  Black Box Replay play/pause & step prev/next key event
  Cmd+C / Cmd+S      Specimen Card copy @2x PNG / save PNG to disk

Privacy & Data Sources:
  Reads local Antigravity transcripts & metadata under ~/.gemini/
  Pricing fetched from LiteLLM (cached 24h) + AGY fallback rate table
  Zero tokens consumed — all local session data stays on your Mac.
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

# Clean up staging folder so build/dmg-staging/AGYMonitor.app doesn't linger
# and trigger duplicate Spotlight / LaunchServices registrations.
rm -rf "$STAGING"

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
