#!/bin/bash
# Build MakeFilm and wrap it into build/MakeFilm.app
#   ./scripts/build-app.sh               release build for this Mac's architecture
#   ./scripts/build-app.sh debug         debug build
#   ./scripts/build-app.sh --universal   release build for Apple Silicon + Intel (for distribution)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    debug|release) CONFIG="$arg" ;;
  esac
done

if [ "$UNIVERSAL" = 1 ]; then
  ARCHS=(--arch arm64 --arch x86_64)
  swift build -c "$CONFIG" "${ARCHS[@]}"
  BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)/MakeFilm"
else
  swift build -c "$CONFIG"
  BIN=".build/$CONFIG/MakeFilm"
fi

APP="build/MakeFilm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MakeFilm"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Localization/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/MakeFilm"))"
