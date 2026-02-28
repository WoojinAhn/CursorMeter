#!/bin/bash
set -euo pipefail

APP_NAME="CursorBar"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building ${APP_NAME} in release mode..."
swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"

# Create Info.plist
cat > "${CONTENTS}/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CursorBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.cursorbar.app</string>
    <key>CFBundleName</key>
    <string>CursorBar</string>
    <key>CFBundleDisplayName</key>
    <string>CursorBar</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Create entitlements
cat > "${CONTENTS}/entitlements.plist" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

# Ad-hoc sign with entitlements
echo "Signing (ad-hoc)..."
codesign -s - --force --deep --entitlements "${CONTENTS}/entitlements.plist" "${APP_BUNDLE}"

# Clean up entitlements from bundle (only needed at signing time)
rm "${CONTENTS}/entitlements.plist"

echo "Done! ${APP_BUNDLE} created."
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
