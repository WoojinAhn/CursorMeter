#!/bin/bash
set -euo pipefail

APP_NAME="CursorMeter"
APP_VERSION="${APP_VERSION:-0.1.0}"
# release.yml sets BUILD_CHANNEL=release; every other invocation is a dev
# build and gets provenance keys stamped into Info.plist (#109). Explicit
# channel, not APP_VERSION inference — a local APP_VERSION=x build must not
# masquerade as a release.
BUILD_CHANNEL="${BUILD_CHANNEL:-dev}"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building ${APP_NAME} v${APP_VERSION} in release mode..."
swift build -c release

DEV_KEYS=""
if [ "${BUILD_CHANNEL}" != "release" ]; then
    # Source-tarball builds have no git metadata — degrade to "unknown"
    # instead of dying under set -e.
    if DEV_COMMIT="$(git rev-parse --short HEAD 2>/dev/null)"; then
        if [ -n "$(git status --porcelain)" ]; then
            DEV_COMMIT="${DEV_COMMIT}-dirty"
        fi
    else
        DEV_COMMIT="unknown"
    fi
    DEV_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    DEV_KEYS="    <key>CMDevBuildCommit</key>
    <string>${DEV_COMMIT}</string>
    <key>CMDevBuildDate</key>
    <string>${DEV_DATE}</string>"
fi

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
${DEV_KEYS}
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
if [ "${BUILD_CHANNEL}" != "release" ]; then
    echo "NOTE: dev build (${DEV_COMMIT}) — automatic release checks are disabled in this bundle."
fi
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
