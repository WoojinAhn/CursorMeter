#!/bin/bash
set -euo pipefail

APP_NAME="CursorMeter"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building ${APP_NAME} v${APP_VERSION} in release mode..."
swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"

# Copy app icon
cp "Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"

# Create Info.plist
cat > "${CONTENTS}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CursorMeter</string>
    <key>CFBundleIdentifier</key>
    <string>com.woojin.CursorMeter</string>
    <key>CFBundleName</key>
    <string>CursorMeter</string>
    <key>CFBundleDisplayName</key>
    <string>CursorMeter</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

echo "Done! ${APP_BUNDLE} v${APP_VERSION} created."
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
