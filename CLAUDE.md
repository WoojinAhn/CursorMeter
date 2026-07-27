# CLAUDE.md — CursorMeter

## Overview

macOS menu bar app for monitoring Cursor IDE usage. Swift 6, pure AppKit (no SwiftUI), zero external dependencies.

## Build & Test

```bash
swift build              # Production build
swift test               # Run all tests (requires Xcode)
swift build -c release   # Release build
```

### App Reinstall (for testing changes)

macOS does not allow overwriting a running app binary. Always follow this sequence:

```bash
git pull --ff-only              # 0. Sync with origin — a stale local main silently
                                #    packages old code (#86; local builds all stamp
                                #    v0.1.0, so the gap is invisible in the app)
pkill -9 -x CursorMeter        # 1. Force kill
rm -rf /Applications/CursorMeter.app  # 2. Delete old bundle
bash Scripts/package_app.sh     # 3. Build release + create .app
cp -r CursorMeter.app /Applications/  # 4. Copy new bundle
open /Applications/CursorMeter.app    # 5. Launch
```

`Scripts/capture-settings.sh` wraps this sequence (with a behind-origin guard)
and then captures per-tab Settings screenshots via AX frames — use it for the
screenshot-refresh step of the Issue Workflow.

- Local builds stamp version 0.1.0 and a `CMDevBuildCommit` Info.plist marker (#109): the app shows "Dev build <hash>" in Settings and skips all update checks. Only `release.yml` (`BUILD_CHANNEL=release`) injects the tag version and omits the marker

## Log Inspection

- `log` is a zsh builtin — use `/usr/bin/log` to invoke macOS unified logging
- `Log.info` entries require `--info --debug` flags: `/usr/bin/log show --predicate 'subsystem == "com.cursormeter"' --info --debug --last 5m`
- **Always add `AND process == "CursorMeter"` to the predicate** — `swift test` runs log under the same subsystem from the xctest host, and mixed output has caused misdiagnosis (phantom session-expiry events)
- Simulate session expiry: `security add-generic-password -U -s com.cursormeter.session -a cursor-cookie-header -w "WorkosCursorSessionToken=INVALID"` → relaunch

## Issue Workflow

Every feature issue follows this sequence:

1. **Test case selection** — Define tests for the logic being changed/added before writing code
2. **Implementation** — Write feature code and test code together
3. **`swift test`** — All tests must pass
4. **Commit/push** — Reference issue number in commit message. **After pushing, check CI** (`gh run list --limit 1`) — the Test workflow ran red for a full day of pushes once (#84 strict-isolation break) and was only noticed when it blocked a release. Note: `test.yml` triggers only on **main push + PR** — feature-branch pushes run no CI, so branch work gets its first CI signal at merge (or open a PR)
5. **Screenshot refresh (UI-visible changes)** — If the change alters anything shown in `docs/screenshots/`, recapture the affected shots in the same issue (AX-path-driven automation; see #91). **PII rule: the real name / company email in the popover header must never appear** — crop the user-info row (precedent: `popover.png`) or use the "Demo User" overlay (precedent: `popover-weekly.png`), and inspect every capture BEFORE `git add`
6. **Post-close check** — After closing an issue, run `gh issue list --state open` and show remaining issues to the user

Out-of-scope discoveries during work (bugs / risks outside the requested change) → record in `.claude/notes.md` (gitignored), do not auto-fix.

## UI Mockup Workflow (AppKit)

Popover/menu-bar 등 시각적 UI 변경 사전 정렬 시 `docs/mockup-<issue>.html`로
before/after side-by-side 작성 → `open` 명령으로 시각 확인 후 사용자와 합의.
AppKit 컨텍스트라 글로벌 CLAUDE.md의 Playwright/Magic MCP UI workflow는 적용
불가 — HTML mockup이 우회로.

## AX-Driven UI Verification

Popover/Settings live checks run through `osascript` System Events — **element paths only, never screen coordinates** (a stray coordinate click once silently corrupted two persisted settings):

- Popover path: `pop over 1 of menu bar item 1 of menu bar 1` (status-item click toggles — retry-loop open, don't assume state). Buttons/sliders inside are addressable by name; the popover is not exposed as a `window`
- `switch` is an AppleScript reserved word; NSSwitch AXPress can double-fire its action — to flip a persisted toggle for a capture, use kill → `defaults write` → relaunch instead of clicking the switch
- Capture via AX frame: `get {position, size}` then `screencapture -x` + `sips` crop (sips silently ignores a crop that keeps the full width — reduce both dimensions)

## Release Workflow

- `release.yml` (tag push) auto-generates body. For curated notes, after workflow completes: `gh release edit <tag> --notes-file <path>` to overwrite
- **Pre-release / beta tags** (e.g. `v0.4.0-beta.1`): `release.yml` does not auto-mark as prerelease. After workflow completes: `gh release edit <tag> --prerelease`. GitHub's `/releases/latest` API auto-excludes prereleases, so `UpdateChecker` won't notify existing stable users
- Roll back a not-yet-distributed release (download_count ≈ 0) and re-tag same version: `gh release delete <tag> --cleanup-tag` then `git fetch --prune --prune-tags origin`
- **Notes tone — user-facing impact only.** Each item must pass the "how does this change what the user experiences?" filter. Skip CI/infra changes, internal refactors, doc updates, action-SHA pinning, test workflow tweaks. Security wins → one-line summary + `SECURITY.md` link, not a bullet list. Internal-only changes are already covered by the Full Changelog link at the bottom.

## Architecture

| File | Role |
|------|------|
| `CursorMeterApp.swift` | App entry, NSApplicationDelegate + NSStatusItem + NSPopover |
| `MenuBarView.swift` | Popover UI (NSViewController, 4-section layout) |
| `SettingsTabViewController.swift` | Settings window root — NSTabViewController (.toolbar), 3 tabs, `updateUI()` fan-out (#99) |
| `SettingsGeneralTabViewController.swift` | General tab: Refresh / Startup / Version+update-check |
| `SettingsNotificationsTabViewController.swift` | Alerts tab: usage alerts, threshold slider, app-status toggle |
| `SettingsAppearanceTabViewController.swift` | Display tab: menu bar text, usage jump, weekly chart |
| `SettingsCardFactory.swift` | Card-row layout factory + `CardBackgroundView`; hard-constraint padding (#101), children must report `preferredContentSize` in `viewWillAppear` |
| `UsageViewModel.swift` | State management, auto-refresh, settings persistence |
| `CursorAPIClient.swift` | API calls (actor, ephemeral URLSession) |
| `UsageModels.swift` | Codable models + display model |
| `WeeklyUsageModels.swift` | Weekly usage codable + display models |
| `WeeklyUsageChartView.swift` | Rolling 7-day bar chart in the popover |
| `UpdateChecker.swift` | GitHub Releases update check (ephemeral session) |
| `ThresholdRangeSlider.swift` | Dual-thumb warning/critical range slider (#81) |
| `CursorAppAuthReader.swift` | Reads Cursor IDE credentials from state.vscdb (#54 IDE auth source) |
| `CircularProgressIcon.swift` | Menu bar progress ring icon + color thresholds |
| `NotificationManager.swift` | Usage threshold notifications (UserNotifications) |
| `LoginWindow.swift` | WKWebView login + two-tier domain whitelist + cookie capture validation |
| `KeychainStore.swift` | Credential storage (Data Protection Keychain) |
| `LogRedactor.swift` | Sensitive data redaction for logs |
| `JumpEffectCoordinator.swift` | Observes `UsageViewModel.lastJump`, swaps `statusItem.button.image` to ⚡/🚀 emoji glyphs on tier 1/2; gates Bold + tier 2 system notification |
| `ExternalURL.swift` | Host-validated wrapper around `NSWorkspace.open` for GitHub URLs derived from the Releases API |
| `CursorActivityWatcher.swift` | Watches Cursor's conversation-search WAL (DispatchSource); debounced event-driven refresh trigger |

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
- **Full endpoint reference** (used + observed-but-unused): [`docs/API_REFERENCE.md`](docs/API_REFERENCE.md). Re-verify against a fresh dashboard capture if schemas drift.

## Conventions

- Swift 6 strict concurrency: `@MainActor`, `actor`, `Sendable`
- CI Xcode 16.4 / macOS 15.5 SDK is stricter than local Xcode on Sendable across `await`. Non-Sendable Apple SDK types (e.g. `UNNotificationSettings`) returned to a `nonisolated` context need `@preconcurrency import` on the framework. Also: a `static let` in a `@MainActor` test class is actor-isolated on CI — referencing it from the `nonisolated` `setUp`/`tearDown` overrides fails there (compiles locally); declare such constants `nonisolated static let`
- Zero external dependencies — macOS SDK only (`Foundation`, `AppKit`, `Security`, `WebKit`, `UserNotifications`)
- `URLSessionConfiguration.ephemeral` — no disk cache (also applies to `UpdateChecker`)
- Keychain via standard macOS Keychain (Data Protection Keychain requires entitlements unavailable to ad-hoc signed apps)
- WebView host whitelist enforced in both `decidePolicyFor navigationAction` and `decidePolicyFor navigationResponse`. Policy detail (two-tier exact + suffix list, ccTLD coverage, accepted residual risk) lives in `SECURITY.md`
- `UsageViewModel` uses `@Observable` (not `@Published`); observers must use `withObservationTracking` + re-arm pattern, not Combine `sink`. New observable state read by UI must also be added to the tracking blocks in `CursorMeterApp` — otherwise UI silently never updates
- Tests must never call `UNUserNotificationCenter.current()` (crashes in SPM test host) or touch the real Keychain — use `UsageViewModel` seams: `init(apiClient:)`+MockURLProtocol, `keychainDeleteHandler`, `sessionExpiredNotifier`, `testHook_setCookieHeader`
