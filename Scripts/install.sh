#!/bin/bash
set -euo pipefail

APP_NAME="CursorMeter"
# Overridable so the installer can be exercised end-to-end without touching
# the real /Applications copy (#111).
APP_DEST="${APP_DEST:-/Applications/${APP_NAME}.app}"
REPO="WoojinAhn/CursorMeter"

WORK_DIR=""
cleanup() {
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Fetch latest release info from GitHub API. `-f` so an HTTP error is a hard
# failure instead of an error page flowing into the parser below.
echo "Fetching latest release..."
RELEASE_JSON=$(curl -fsL "https://api.github.com/repos/${REPO}/releases/latest")
VERSION=$(echo "$RELEASE_JSON" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')

if [ -z "$VERSION" ]; then
    echo "Error: Failed to fetch release info."
    exit 1
fi

ZIP_NAME="${APP_NAME}-${VERSION#v}.zip"
# Match the exact asset name — picking the first browser_download_url breaks as
# soon as the release carries any other asset (checksums, etc.).
ZIP_URL=$(echo "$RELEASE_JSON" \
    | grep -o "\"browser_download_url\": *\"[^\"]*${ZIP_NAME}\"" \
    | head -n1 \
    | sed 's/.*"browser_download_url": *"//;s/"$//')

if [ -z "$ZIP_URL" ]; then
    echo "Error: Release ${VERSION} has no asset named ${ZIP_NAME}."
    exit 1
fi

echo "Latest version: ${VERSION}"

WORK_DIR=$(mktemp -d)
ZIP_PATH="${WORK_DIR}/${ZIP_NAME}"

echo "Downloading ${ZIP_NAME}..."
curl -fsL "$ZIP_URL" -o "$ZIP_PATH"

# Extract and validate BEFORE removing the installed copy — a corrupt download
# must not leave the user with no app at all.
echo "Extracting..."
EXTRACT_DIR="${WORK_DIR}/extract"
mkdir -p "$EXTRACT_DIR"
ditto -xk "$ZIP_PATH" "$EXTRACT_DIR"

NEW_APP="${EXTRACT_DIR}/${APP_NAME}.app"
if [ ! -x "${NEW_APP}/Contents/MacOS/${APP_NAME}" ]; then
    echo "Error: downloaded archive does not contain a usable ${APP_NAME}.app."
    echo "Your existing installation was left untouched."
    exit 1
fi

# Quarantine is not set on curl downloads, but a manually-downloaded archive
# handed to this script would carry it. Kept until Developer ID signing +
# notarization lands (see #53 M-6 / #31).
xattr -cr "$NEW_APP"

if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "Quitting running ${APP_NAME}..."
    pkill -x "$APP_NAME"
    sleep 1
fi

if [ -d "$APP_DEST" ]; then
    echo "Removing old ${APP_NAME}..."
    rm -rf "$APP_DEST"
fi

mv "$NEW_APP" "$APP_DEST"

echo "Launching ${APP_NAME}..."
open "$APP_DEST"

echo "Done! ${APP_NAME} ${VERSION} installed."
