#!/bin/bash
# Reinstall the app, open Settings, and capture per-tab screenshots via AX
# element frames (element paths only, never screen coordinates — CLAUDE.md
# "AX-Driven UI Verification").
#
# Usage: bash Scripts/capture-settings.sh [output-dir] [tab ...]
#   output-dir  default: docs/screenshots/tmp (gitignored scratch; inspect for
#               PII BEFORE copying anything into docs/screenshots/)
#   tabs        default: General Alerts Display
#
# AppleScript notes baked in from past sessions:
#   - integers must be coerced: (x as string) & "," — bare `x & ","` builds a list
#   - `th`/`st`/`nd`/`rd` are ordinal suffixes, unusable as variable names
#   - nested static texts are reachable only via `entire contents of window`
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-docs/screenshots/tmp}"
shift 2>/dev/null || true
TABS=("$@")
[ ${#TABS[@]} -eq 0 ] && TABS=(General Alerts Display)
mkdir -p "$OUT"

# 0. Behind-origin guard (#86): a stale local main silently packages old code,
#    and local builds all stamp v0.1.0 so the gap is invisible in the app.
#    Warn-and-abort only when strictly behind; ahead/diverged is normal mid-work.
git fetch origin main --quiet
if [ "$(git rev-list --count HEAD..origin/main)" -gt 0 ] && [ "${SKIP_SYNC:-0}" != "1" ]; then
    echo "ERROR: local HEAD is behind origin/main — run 'git pull --ff-only'" >&2
    echo "       (or SKIP_SYNC=1 to capture a deliberately old build)" >&2
    exit 1
fi

# 1. Reinstall (CLAUDE.md App Reinstall sequence)
pkill -9 -x CursorMeter || true
rm -rf /Applications/CursorMeter.app
bash Scripts/package_app.sh
cp -r CursorMeter.app /Applications/
open /Applications/CursorMeter.app
sleep 2

# 2. Open Settings via the popover (retry loop — the status-item click toggles,
#    so never assume open/closed state).
osascript <<'EOF'
tell application "System Events"
  tell process "CursorMeter"
    repeat with i from 1 to 3
      click menu bar item 1 of menu bar 1
      delay 0.6
      try
        set p to pop over 1 of menu bar item 1 of menu bar 1
        exit repeat
      end try
    end repeat
    click button "Settings..." of pop over 1 of menu bar item 1 of menu bar 1
    delay 0.9
  end tell
end tell
EOF

# 3. Per tab: select via toolbar button name, read the AX window frame, capture.
for TAB in "${TABS[@]}"; do
  GEOM=$(osascript <<EOF
tell application "System Events"
  tell process "CursorMeter"
    click button "$TAB" of toolbar 1 of window 1
    delay 0.9
    set {posX, posY} to position of window 1
    set {sizeW, sizeH} to size of window 1
    return (posX as string) & "," & (posY as string) & "," & (sizeW as string) & "," & (sizeH as string)
  end tell
end tell
EOF
)
  IFS=, read -r X Y W H <<<"$GEOM"
  screencapture -x -R"$X,$Y,$W,$H" "$OUT/settings-$TAB.png"
  echo "captured $OUT/settings-$TAB.png (${W}x${H})"
done

echo "REMINDER: inspect every capture for PII BEFORE git add (CLAUDE.md rule)."
