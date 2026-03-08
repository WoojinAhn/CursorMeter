#!/bin/bash
set -euo pipefail

APP_NAME="CursorMeter"
APP_DEST="/Applications/${APP_NAME}.app"
REPO="WoojinAhn/CursorMeter"

# Fetch latest release info from GitHub API
echo "Fetching latest release..."
RELEASE_JSON=$(curl -sL "https://api.github.com/repos/${REPO}/releases/latest")
VERSION=$(echo "$RELEASE_JSON" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')
ZIP_URL=$(echo "$RELEASE_JSON" | grep -m1 '"browser_download_url"' | sed 's/.*"browser_download_url": *"//;s/".*//')

if [ -z "$VERSION" ] || [ -z "$ZIP_URL" ]; then
    echo "Error: Failed to fetch release info."
    exit 1
fi

ZIP_NAME="${APP_NAME}-${VERSION#v}.zip"
echo "Latest version: ${VERSION}"

# Download
echo "Downloading ${ZIP_NAME}..."
curl -sL "$ZIP_URL" -o "/tmp/${ZIP_NAME}"

# 1. Quit running app
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "Quitting running ${APP_NAME}..."
    pkill -x "$APP_NAME"
    sleep 1
fi

# 2. Remove old app
if [ -d "$APP_DEST" ]; then
    echo "Removing old ${APP_NAME}..."
    rm -rf "$APP_DEST"
fi

# 3. Unzip
echo "Extracting..."
TEMP_DIR=$(mktemp -d)
ditto -xk "/tmp/${ZIP_NAME}" "$TEMP_DIR"

# 4. Remove quarantine attribute
xattr -cr "${TEMP_DIR}/${APP_NAME}.app"

# 5. Move to /Applications
mv "${TEMP_DIR}/${APP_NAME}.app" "$APP_DEST"
rm -rf "$TEMP_DIR" "/tmp/${ZIP_NAME}"

echo "Launching ${APP_NAME}..."
open "$APP_DEST"

echo "Done! ${APP_NAME} ${VERSION} installed."
