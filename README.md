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

<p align="center">
  <img src="docs/screenshots/menubar.png" alt="Menu bar" height="40">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/screenshots/popover.png" alt="Popover" width="280">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/screenshots/settings.png" alt="Settings" width="280">
</p>

## Features

- Gauge ring icon in menu bar with color thresholds (green → yellow → red)
- View billing usage, per-model request counts, and reset date from the menu bar
- macOS notifications when usage reaches customizable thresholds (default: 65%/90%)
- Menu bar display mode toggle: fraction (used/limit) or percentage (%)
- Settings UI (refresh interval, notification thresholds, menu bar display format)
- Launch at login support
- In-app update checker
- In-app WebView login (Google, GitHub, Enterprise SSO)
- Auto-refresh at configurable intervals (1/2/5/15 min)
- Keychain-based credential storage
- Pure AppKit — minimal memory footprint (~13 MB RSS)

## Security

- Zero external dependencies (macOS SDK only)
- WebView domain whitelist enforced
- `URLSessionConfiguration.ephemeral` (no disk cache)
- No JavaScript injection
- Keychain-based credential storage

## Requirements

- macOS 14 (Sonoma) or later

## Installation

1. Download the latest `.zip` from [Releases](https://github.com/WoojinAhn/CursorMeter/releases)
2. Unzip and drag `CursorMeter.app` to `/Applications`
3. On first launch, macOS may block the app (unsigned). To bypass:
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

Unit tests (LogRedactor, UsageDisplayData, DomainWhitelist, CircularProgressIcon, NotificationManager) + Integration tests (CursorAPIClient with URLProtocol mock). See [test-checklist.md](docs/test-checklist.md) for manual test scenarios.

## Disclaimer

This app uses Cursor's **undocumented internal APIs** (`/api/usage`, `/api/usage-summary`, `/api/auth/me`). These endpoints may change or be blocked at any time without notice.

## Roadmap

- [ ] Switch progress display to on-demand when request quota exhausted ([#36](https://github.com/WoojinAhn/CursorMeter/issues/36))

## License

MIT
