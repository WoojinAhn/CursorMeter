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
# `|| true` so the explicit diagnostics below run instead of set -e killing the
# script with no message (GitHub's unauthenticated API returns 403 once the
# hourly rate limit is hit — a real case on shared IPs).
RELEASE_JSON=$(curl -fsL "https://api.github.com/repos/${REPO}/releases/latest") || true

if [ -z "$RELEASE_JSON" ]; then
    echo "Error: Could not reach the GitHub releases API."
    echo "If you are rate-limited or offline, download the .zip manually from:"
    echo "  https://github.com/${REPO}/releases/latest"
    exit 1
fi

VERSION=$(echo "$RELEASE_JSON" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')

if [ -z "$VERSION" ]; then
    echo "Error: Failed to parse release info."
    exit 1
fi

ZIP_NAME="${APP_NAME}-${VERSION#v}.zip"
# Match the exact asset name — picking the first browser_download_url breaks as
# soon as the release carries any other asset (checksums, etc.).
ZIP_URL=$(echo "$RELEASE_JSON" \
    | grep -o "\"browser_download_url\": *\"[^\"]*${ZIP_NAME}\"" \
    | head -n1 \
    | sed 's/.*"browser_download_url": *"//;s/"$//') || true

if [ -z "$ZIP_URL" ]; then
    echo "Error: Release ${VERSION} has no asset named ${ZIP_NAME}."
    exit 1
fi

echo "Latest version: ${VERSION}"

WORK_DIR=$(mktemp -d)
ZIP_PATH="${WORK_DIR}/${ZIP_NAME}"

echo "Downloading ${ZIP_NAME}..."
curl -fsL "$ZIP_URL" -o "$ZIP_PATH"

# Checksum check when the release publishes one. This detects a corrupted or
# wrong download; it is NOT publisher authentication — the hash comes from the
# same repo as the archive (see #53 M-6). Releases made before checksums were
# published simply skip this.
CHECKSUM_NAME="${ZIP_NAME}.sha256"
CHECKSUM_URL=$(echo "$RELEASE_JSON" \
    | grep -o "\"browser_download_url\": *\"[^\"]*${CHECKSUM_NAME}\"" \
    | head -n1 \
    | sed 's/.*"browser_download_url": *"//;s/"$//') || true

if [ -n "$CHECKSUM_URL" ]; then
    echo "Verifying checksum..."
    curl -fsL "$CHECKSUM_URL" -o "${ZIP_PATH}.sha256"
    EXPECTED=$(awk '{print $1}' "${ZIP_PATH}.sha256")
    ACTUAL=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
    if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "Error: checksum mismatch for ${ZIP_NAME}."
        echo "  expected: ${EXPECTED:-<empty>}"
        echo "  actual:   ${ACTUAL}"
        echo "Aborting; your existing installation was left untouched."
        exit 1
    fi
    echo "Checksum OK."
else
    echo "Note: release ${VERSION} publishes no checksum; skipping verification."
fi

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
