**English** | [한국어](README.ko.md)

<p align="center">
  <img src="Resources/AppIcon.png" width="80" alt="CursorMeter icon">
</p>

<h1 align="center">CursorMeter</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/github/license/WoojinAhn/CursorMeter" alt="License">
  <img src="https://img.shields.io/github/v/release/WoojinAhn/CursorMeter" alt="Release">
</p>

A lightweight macOS menu bar app for monitoring [Cursor](https://www.cursor.com/) IDE usage at a glance — no browser tab needed.

Unlike in-editor extensions, CursorMeter runs independently as a native macOS app: always visible in the menu bar whether the IDE is open or not, with persistent login via Keychain across restarts.

## Features

- Gauge ring icon in menu bar with color thresholds (green → yellow → red)
- View billing usage, request counts, and reset date from the menu bar
- macOS notifications when usage reaches customizable thresholds (default: 80%/90%)
- **Usage-jump effect** — menu bar icon flashes ⚡ on a moderate jump and 🚀 on a Max-mode-sized jump, so a sudden spike is hard to miss. Three intensity levels (Quiet / Normal / Bold) and a choice of glyph style (⚡/🚀 or 💲/💸); Bold also raises a macOS notification on tier-2 jumps.
- **Weekly usage chart** (all plans) — rolling 7-day bar graph in the popover. Bar heights sum Cursor's weighted billing units (`requestsCosts`), so a single Max-mode Opus call correctly outweighs many light auto-completes. Hover tooltip switches per day: raw weighted-unit integer on plan-covered days, real dollars charged on on-demand days. Configurable today-highlight (Outline / Dim others / Both).
- Menu bar display mode: icon only, fraction (used/limit), or percentage (%)
- Settings UI (refresh interval, notification thresholds, menu bar display format, jump-effect intensity, weekly-chart style)
- Launch at login support
- In-app update checker
- **Zero-config login** — if the Cursor IDE is signed in on the same Mac, CursorMeter connects automatically (no separate login). If the IDE isn't signed in yet, the popover guides you: one click opens the IDE, and the app connects itself the moment you finish signing in. Logging out pauses the automatic IDE connection until you reconnect.
- **Browser (WebView) login is deprecated** — it still works (Google, GitHub, Enterprise SSO), but is hidden behind an opt-in: Settings → General → "Enable browser login". It reappears automatically only when the Cursor IDE app is not installed, so there is always at least one way to connect.
- Auto-refresh at configurable intervals (1/2/5/15 min)
- **Activity-driven refresh** — when you use Cursor, the app refreshes within ~1 minute instead of waiting for the next poll, so usage stays current right after a burst of work. Interval polling remains the fallback. Toggle in Settings → Refresh → "Refresh on Cursor activity".
- Keychain-based credential storage
- Pure AppKit — light memory footprint (~17 MB idle, ~33 MB once the popover has been opened; macOS retains AppKit / popover state for instant re-opens). If you don't need the weekly chart and want the older ~15 MB footprint instead, [v0.2.1](https://github.com/WoojinAhn/CursorMeter/releases/tag/v0.2.1) is the previous stable release.

## Security

- Zero external dependencies (macOS SDK only)
- Two-tier WebView host whitelist (exact + suffix), with `https`-scheme enforcement on both navigation action and response
- Required-cookie validation before persisting a login session
- Host-validated `NSWorkspace.open` for any URL derived from the GitHub Releases API
- `URLSessionConfiguration.ephemeral` (no disk cache)
- Keychain-based credential storage

See [`SECURITY.md`](SECURITY.md) for the full threat model and reporting policy.

## Requirements

- macOS 14 (Sonoma) or later

## Installation

1. Download the latest `.zip` from [Releases](https://github.com/WoojinAhn/CursorMeter/releases)
2. Optional — if the release includes a `.zip.sha256` asset, you can check the download:
   `shasum -a 256 -c CursorMeter-<version>.zip.sha256`
   (This detects a corrupted or wrong file. It is not a publisher signature — the app is ad-hoc signed, see step 4.)
3. Unzip and drag `CursorMeter.app` to `/Applications`
4. On first launch, macOS may block the app (unsigned). To bypass:
   - **Right-click** the app → **Open** → click **Open** in the dialog
   - Or: System Settings → Privacy & Security → click **Open Anyway**

## Build from Source

```bash
# Build + create .app bundle (ad-hoc signed)
bash Scripts/package_app.sh

# Install
cp -r CursorMeter.app /Applications/
```

Requires Swift 6.0+ and Xcode.

## Testing

```bash
swift test    # Run all tests (requires Xcode)
```

400+ tests across 24 suites: view-model logic (credential chain, stale detection, thresholds, jump events), custom controls (dual-thumb range slider), notification rules, log redaction, and API-client integration via a URLProtocol mock. See [test-checklist.md](docs/test-checklist.md) for manual test scenarios.

## Disclaimer

This app uses several of Cursor's **undocumented internal endpoints** (usage, auth, and dashboard APIs — see [`docs/API_REFERENCE.md`](docs/API_REFERENCE.md) for the full list). These endpoints may change or be blocked at any time without notice.

## Contributing

Found a bug or have an idea? [Open an issue](https://github.com/WoojinAhn/CursorMeter/issues) — feedback and suggestions are always welcome. Pull requests are not accepted at this time.

## Screenshots

<table>
  <tr>
    <th align="center">Menu bar</th>
    <th align="center">Popover</th>
    <th align="center">Weekly chart</th>
    <th align="center">Settings</th>
  </tr>
  <tr>
    <td align="center" valign="top"><img src="docs/screenshots/menubar.png" alt="Menu bar" height="40"></td>
    <td align="center" valign="top"><img src="docs/screenshots/popover.png" alt="Popover" width="240"></td>
    <td align="center" valign="top"><img src="docs/screenshots/popover-weekly.png" alt="Weekly chart" width="240"></td>
    <td align="center" valign="top"><img src="docs/screenshots/settings.png" alt="Settings" width="240"></td>
  </tr>
</table>

## License

MIT
