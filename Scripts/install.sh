#!/bin/bash
set -euo pipefail

APP_NAME="CursorMeter"
APP_DEST="/Applications/${APP_NAME}.app"
ZIP_NAME=""

# Find the zip file
for f in ${APP_NAME}-*.zip ${APP_NAME}.zip; do
    [ -f "$f" ] && ZIP_NAME="$f" && break
done

if [ -z "$ZIP_NAME" ]; then
    echo "Error: ${APP_NAME}-*.zip not found in current directory."
    echo "Usage: cd ~/Downloads && bash install.sh"
    exit 1
fi

echo "Installing ${APP_NAME} from ${ZIP_NAME}..."

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
echo "Extracting ${ZIP_NAME}..."
TEMP_DIR=$(mktemp -d)
ditto -xk "$ZIP_NAME" "$TEMP_DIR"

# 4. Remove quarantine attribute
xattr -cr "${TEMP_DIR}/${APP_NAME}.app"

# 5. Move to /Applications
mv "${TEMP_DIR}/${APP_NAME}.app" "$APP_DEST"
rm -rf "$TEMP_DIR"

echo "Launching ${APP_NAME}..."
open "$APP_DEST"

echo "Done!"
