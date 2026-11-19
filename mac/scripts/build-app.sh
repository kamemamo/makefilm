#!/bin/bash
# Build MakeFilm and wrap it into build/MakeFilm.app
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/MakeFilm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/MakeFilm" "$APP/Contents/MacOS/MakeFilm"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"
