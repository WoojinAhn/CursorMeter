**English** | [한국어](README.ko.md)

# CursorMeter

A lightweight macOS menu bar app for monitoring [Cursor](https://www.cursor.com/) IDE usage at a glance — no browser tab needed.

<!-- TODO: Add screenshots (menu bar icon + popover UI) -->

## Features

- Pie chart icon in menu bar visualizing usage (green/yellow/red color levels)
- View request usage (used/limit) and reset date from the menu bar
- macOS notifications when usage reaches thresholds (80%/90%, customizable)
- Settings UI (refresh interval, notification thresholds, menu bar display format)
- In-app WebView login (Google, GitHub, Enterprise SSO)
- Auto-refresh at configurable intervals (1/2/5/15 min)
- Keychain-based credential storage

## Security

- Zero external dependencies (macOS SDK only)
- WebView domain whitelist enforced
- `URLSessionConfiguration.ephemeral` (no disk cache)
- No JavaScript injection
- Data Protection Keychain (no access prompts)

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0+ (for building)

## Build & Install

```bash
# Build + create .app bundle (ad-hoc signed)
bash Scripts/package_app.sh

# Install
cp -r CursorMeter.app /Applications/
```

## Testing

```bash
swift test    # Run all tests (requires Xcode)
```

Unit tests (LogRedactor, UsageDisplayData, DomainWhitelist, CircularProgressIcon, NotificationManager) + Integration tests (CursorAPIClient with URLProtocol mock). See [test-checklist.md](docs/test-checklist.md) for manual test scenarios.

## License

MIT
