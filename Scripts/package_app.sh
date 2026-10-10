#!/bin/bash
set -euo pipefail

APP_NAME="CursorMeter"
APP_VERSION="${APP_VERSION:-0.1.0}"
# Artifact verification in test.yml sets BUILD_CHANNEL=release for PR/main CI
# (0.0.0-ci) and for tag releases called by release.yml (the tag version).
# Other invocations default to dev and get provenance keys in Info.plist (#109).
# Select the channel explicitly; APP_VERSION alone does not make a release build.
BUILD_CHANNEL="${BUILD_CHANNEL:-dev}"
if [[ ${CM_DEV_SIGNING_IDENTITY+x} ]]; then
    if [ "$BUILD_CHANNEL" = "release" ]; then
        echo "Error: CM_DEV_SIGNING_IDENTITY is only supported for local dev builds." >&2
        exit 1
    fi
    if [[ ! "$CM_DEV_SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        echo "Error: CM_DEV_SIGNING_IDENTITY must be a 40-digit certificate SHA-1 fingerprint." >&2
        exit 1
    fi
fi
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
case "$BUILD_ARCH" in
    arm64|x86_64) ;;
    *) echo "Error: Unsupported build architecture: ${BUILD_ARCH}"; exit 1 ;;
esac
BUILD_TRIPLE="${BUILD_ARCH}-apple-macosx14.0"
APP_BUNDLE="${APP_OUTPUT_DIR:-.}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building ${APP_NAME} v${APP_VERSION} for ${BUILD_ARCH} in release mode..."
swift build -c release --triple "$BUILD_TRIPLE"
BUILD_DIR=$(swift build -c release --triple "$BUILD_TRIPLE" --show-bin-path)
ACTUAL_ARCH=$(lipo -archs "${BUILD_DIR}/${APP_NAME}")
if [ "$ACTUAL_ARCH" != "$BUILD_ARCH" ]; then
    echo "Error: Expected ${BUILD_ARCH} binary, got ${ACTUAL_ARCH}."
    exit 1
fi

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
# Keep signing inputs outside the bundle so its sealed resources stay intact.
ENTITLEMENTS_PATH=$(mktemp)
trap 'rm -f "$ENTITLEMENTS_PATH"' EXIT
cat > "$ENTITLEMENTS_PATH" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

if [[ ${CM_DEV_SIGNING_IDENTITY+x} ]]; then
    echo "Signing (local development identity)..."
    codesign --sign "$CM_DEV_SIGNING_IDENTITY" --force --deep \
        --entitlements "$ENTITLEMENTS_PATH" --timestamp=none \
        --requirements "=designated => identifier \"com.woojin.CursorMeter\" and certificate leaf = H\"${CM_DEV_SIGNING_IDENTITY}\"" \
        "$APP_BUNDLE"
else
    echo "Signing (ad-hoc)..."
    codesign -s - --force --deep --entitlements "$ENTITLEMENTS_PATH" "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"

echo "Done! ${APP_BUNDLE} v${APP_VERSION} created."
if [ "${BUILD_CHANNEL}" != "release" ]; then
    echo "NOTE: dev build (${DEV_COMMIT}) — automatic release checks are disabled in this bundle."
fi
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
