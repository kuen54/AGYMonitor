#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BUILD_CHECK=0
for arg in "$@"; do
    if [ "$arg" = "--build" ]; then
        BUILD_CHECK=1
    fi
done

echo "🔎 [1/4] Linting Info.plist..."
plutil -lint Info.plist

echo "🐍 [2/4] Syntax-checking analyze_usage.py..."
/usr/bin/python3 -m py_compile Resources/analyze_usage.py

echo "🧪 [3/4] Running Python unit & parity tests..."
/usr/bin/python3 -m unittest discover -s Tests -p "test_*.py" -v

echo "🧪 [4/4] Running AGYCore Swift unit tests..."
swift test

if [ "$BUILD_CHECK" = "1" ]; then
    echo "🔨 [--build] Building universal app bundle & verifying signature..."
    bash build.sh --skip-dmg
    codesign --verify --deep --strict build/AGYMonitor.app
    echo "✅ App bundle build & strict codesign verification passed!"
fi

echo "✅ All AGYMonitor checks passed!"
