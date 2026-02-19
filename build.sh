#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
SAVER_DEST="$HOME/Library/Screen Savers/SoundStream2.saver"

echo "=== Building SoundStream2 Screen Saver ==="

# Build screensaver
xcodebuild -project "$PROJECT_DIR/Soundstream.xcodeproj" \
    -target SoundStream2 \
    -configuration Release \
    SYMROOT="$BUILD_DIR" \
    2>&1 | tail -5

SAVER="$BUILD_DIR/Release/SoundStream2.saver"
if [ ! -d "$SAVER" ]; then
    echo "ERROR: Saver build failed"
    exit 1
fi
echo "Saver built OK"

# Build helper app
echo ""
echo "=== Building SoundStream2Helper ==="
HELPER_APP="$BUILD_DIR/SoundStream2Helper.app"
mkdir -p "$HELPER_APP/Contents/MacOS"

swiftc -O \
    -o "$HELPER_APP/Contents/MacOS/SoundStream2Helper" \
    -import-objc-header "$PROJECT_DIR/SoundStream2Helper/shm_bridge.h" \
    "$PROJECT_DIR/SoundStream2Helper/main.swift" \
    -framework ScreenCaptureKit -framework Accelerate \
    -framework AVFoundation -framework CoreMedia -framework CoreGraphics \
    2>&1 | grep -v warning || true

cat > "$HELPER_APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.henry.soundstream2-helper</string>
	<key>CFBundleName</key>
	<string>SoundStream2Helper</string>
	<key>CFBundleExecutable</key>
	<string>SoundStream2Helper</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSScreenCaptureUsageDescription</key>
	<string>SoundStream2 needs to capture system audio to visualize sound as flowing particles.</string>
</dict>
</plist>
PLIST

echo "Helper built OK"

# Sign helper with developer certificate (if available)
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -n "$IDENTITY" ]; then
    echo "Signing helper with: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$HELPER_APP" 2>&1
fi

# Install
echo ""
echo "=== Installing ==="
rm -rf "$SAVER_DEST"
cp -R "$SAVER" "$SAVER_DEST"
cp -R "$HELPER_APP" "$SAVER_DEST/Contents/Resources/"
echo "Installed to: $SAVER_DEST"

echo ""
echo "=== Done ==="
echo "First time setup: run the helper app manually to grant screen capture permission:"
echo "  open \"$SAVER_DEST/Contents/Resources/SoundStream2Helper.app\""
echo ""
echo "After granting permission, the screensaver will work automatically."
