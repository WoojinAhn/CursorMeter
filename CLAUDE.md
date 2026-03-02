# CLAUDE.md — CursorMeter

## Overview

macOS menu bar app for monitoring Cursor IDE usage. Swift 6, SwiftUI, zero external dependencies.

## Build & Test

```bash
swift build              # Production build
swift test               # Run all tests (requires Xcode)
swift build -c release   # Release build
```

## Issue Workflow

Every feature issue follows this sequence:

1. **Test case selection** — Define tests for the logic being changed/added before writing code
2. **Implementation** — Write feature code and test code together
3. **`swift test`** — All tests must pass (currently 111)
4. **Commit/push** — Reference issue number in commit message
5. **Post-close check** — After closing an issue, run `gh issue list --state open` and show remaining issues to the user

## Architecture

| File | Role |
|------|------|
| `CursorMeterApp.swift` | App entry, MenuBarExtra + Settings scene |
| `MenuBarView.swift` | Popover UI (4-section layout) |
| `UsageViewModel.swift` | State management, auto-refresh, settings persistence |
| `CursorAPIClient.swift` | API calls (actor, ephemeral URLSession) |
| `UsageModels.swift` | Codable models + display model |
| `CircularProgressIcon.swift` | Menu bar progress ring icon + color thresholds |
| `NotificationManager.swift` | Usage threshold notifications (UserNotifications) |
| `SettingsView.swift` | Settings window UI (refresh, notifications, display) |
| `LoginWindow.swift` | WKWebView login + domain whitelist |
| `KeychainStore.swift` | Credential storage (Data Protection Keychain) |
| `LogRedactor.swift` | Sensitive data redaction for logs |

## Cursor API

Two undocumented endpoints used (cookie-based auth, no official schema):

| Endpoint | Purpose | Unit |
|----------|---------|------|
| `/api/usage-summary` | Primary — billingCycleEnd, plan %, membershipType | USD cents |
| `/api/usage` | Supplementary — request counts per model | requests |
| `/api/auth/me` | User info (email, name) | — |

- `UsageViewModel.refresh()` calls all three in parallel with graceful degradation
- `/api/usage` uses dynamic key parsing (no hardcoded model names)
- Reference project: [steipete/CodexBar](https://github.com/steipete/CodexBar) uses same dual-API strategy

## Conventions

- Swift 6 strict concurrency: `@MainActor`, `actor`, `Sendable`
- Zero external dependencies — macOS SDK only (`Foundation`, `Security`, `WebKit`, `SwiftUI`, `UserNotifications`)
- `URLSessionConfiguration.ephemeral` — no disk cache
- Keychain with `kSecUseDataProtectionKeychain: true` — no permission prompts
- WebView domain whitelist enforced in `decidePolicyFor`
