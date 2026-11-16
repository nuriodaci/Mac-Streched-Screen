#!/bin/bash
# Builds Mac-Streched-Screen.app from the SwiftPM executable.
# Usage: Scripts/build-app.sh [debug|release] [output-directory]
set -euo pipefail

CONFIG="${1:-release}"
OUTPUT_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)/dist}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mac-Streched-Screen"
BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
BUNDLE_ID="org.macstrechedscreen.app"
VERSION="0.1.0"
IDENTITY="${SIGN_IDENTITY:--}"
case "$CONFIG" in debug|release) ;; *) echo "Use debug or release" >&2; exit 64 ;; esac

cd "$ROOT"
echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/src" -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/src"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
test -x "$BINARY"
test -x "$BIN_DIR/StretchRestoreHelper"

echo "==> Assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Helpers"
cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/StretchRestoreHelper" "$BUNDLE/Contents/Helpers/StretchRestoreHelper"
cp "$ROOT/README.md" "$BUNDLE/Contents/Resources/README.md"
cp "$ROOT/LICENSE" "$BUNDLE/Contents/Resources/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Stretch Screen</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Stretch Screen</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT licensed</string>
</dict>
</plist>
PLIST

# Remove linker debug-map object paths before distributing the executables.
if [ "$CONFIG" = "release" ]; then
  strip -S "$BUNDLE/Contents/MacOS/$APP_NAME" "$BUNDLE/Contents/Helpers/StretchRestoreHelper"
fi

echo "==> Signing nested helper, then app"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$BUNDLE/Contents/Helpers/StretchRestoreHelper"
  codesign --force --sign - "$BUNDLE"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE/Contents/Helpers/StretchRestoreHelper"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$BUNDLE"

echo "==> Done: $BUNDLE"
