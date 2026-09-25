**English** | [한국어](SECURITY.ko.md)

# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in CursorMeter, **please do not open a public issue.** Use GitHub's Private Vulnerability Reporting:

**Report**: [github.com/WoojinAhn/CursorMeter/security/advisories/new](https://github.com/WoojinAhn/CursorMeter/security/advisories/new)

### What to include

- Description of the vulnerability
- Steps to reproduce
- Expected impact
- Affected version (CursorMeter release tag and macOS version)

### Process

1. You report privately via the GitHub advisory form above
2. Acknowledgement within 48 hours
3. Fix is developed and tested
4. New release is published
5. Vulnerability is disclosed publicly via the GitHub advisory

---

## Threat Model

CursorMeter is a menu bar app that calls undocumented Cursor API endpoints using cookie-based session credentials. The protected assets are:

- **Cursor session cookies** (Keychain-stored), reusable for the lifetime of the session token
- **Account email / name**, derived from `/api/auth/me`
- **Recent usage snapshot**, containing up to 30 bounded display entries and their original retrieval time

The login WebView is the only place CursorMeter loads third-party origins. Cursor usage API requests, including `/api/usage-summary`, `/api/usage`, `/api/auth/me`, and the dashboard event endpoint, go directly to `cursor.com` over HTTPS using `URLSessionConfiguration.ephemeral`. HTTP responses are not cached to disk; the bounded snapshot below is separate.

## Cursor IDE Credential Reuse (#54)

When a Cursor IDE installation is signed in on the same Mac, CursorMeter derives its session from the IDE instead of asking the user to log in again:

- **What is read:** `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, a single key — `cursorAuth/accessToken`.
- **How:** a read-only SQLite connection (`SQLITE_OPEN_READONLY`, 250 ms busy timeout), opened and closed within each read. The IDE's store is never written or locked.
- **What is never read:** `cursorAuth/refreshToken` or any other key. CursorMeter never performs token refresh itself — it only reuses the access token the IDE already maintains.
- **Logging:** the synthesized session header is treated like every other credential — never logged (see LogRedactor policy).
- **Threat model:** this is the user's own credential on the user's own machine, inside the same trust boundary as the Keychain-stored cookie CursorMeter already holds. No new secret class is introduced; the browser-login (WebView) path remains available and is used as fallback.

## Local Recent Usage Snapshot

- **Location and bound:** one versioned JSON file at `~/Library/Application Support/CursorMeter/recent-usage-v1.json`, limited to 30 entries and 256 KiB. It is replaced, not appended to an archive. Each Mac stores its own snapshot.
- **Contents:** event dates, optional model names, display types, token totals, original server-provided cents, the original cache time, binding digests, and a nonsecret validity token. No conversation content, raw responses, account email/name, or plaintext credentials are stored in this file.
- **File protection:** the app directory is set to 0700 and each atomic file replacement to 0600. Binding digests support equality checks; they are not encryption or anonymization. Other processes running as the same user remain inside the local trust boundary.
- **Restoration:** the exact previously successful outbound credential permits cached display. A rotated credential requires the existing authenticated `/api/auth/me.sub` response and the same resolved personal/team request scope before held data is shown. No additional identity request is made.
- **Invalidation:** logout, session expiry, and established account/scope changes invalidate cached data. Rejected credentials clear ineligible cached rows. A synchronously committed preferences token makes old files ineligible before queued deletion; stale asynchronous writes cannot make them valid again. Deletion is best effort, not a secure-erasure guarantee.
- **Persistence failure:** if the validity token cannot be committed, disk restoration and saving are disabled for that process and deletion is attempted. Valid in-memory data can still be shown. Durable invalidation cannot be guaranteed if the OS rejects both the metadata write and file removal.

## Split Usage Storage

- **Amounts:** `~/Library/Application Support/CursorMeter/cycle-usage-v1.json` stores one aggregate-only cycle snapshot, bounded to 1 MiB. It includes source percentages, dollar totals, coverage, estimate provenance, timestamps, and hashed account/scope identities; it contains no raw events, names, emails, cookies, or conversation text. Restore requires the same verified subject, personal scope, plan and active cycle, and a snapshot at most 24 hours old. Restored data never seeds jump baselines or alert history.
- **Alert ledger:** `~/Library/Application Support/CursorMeter/SplitAlerts/` stores hashed successful-threshold identities and cycle end dates, bounded to 4,096 records and 1 MiB per account file. The current cycle remains eligible throughout that cycle; prior cycles expire seven days after their end. Failed deliveries are not recorded. Bold jumps are not persisted.
- **Identity and files:** only a freshly verified subject enables new persistent writes. Email-only identity remains in memory. Files are atomically replaced with mode 0600; hashes are binding keys, not encryption or anonymization. Generation/operation checks reject retired asynchronous writes. Logout attempts to remove the current account's files; deletion is best effort, not secure erasure, and OS-level write/removal failures can leave an older file on disk.
- **Requests:** bounded monthly collection uses separate DTOs and does not persist its raw response bodies. Enrichment failures cannot invalidate credentials; only the existing primary authentication responses can do so.

## WebView Whitelist Policy

The login WebView (`LoginWindow.swift`) validates every navigation against a two-tier host whitelist. The same check runs in both `decidePolicyFor navigationAction` and `decidePolicyFor navigationResponse`. Both callbacks also enforce `scheme == "https"` — a redirect to plain HTTP (or to `file:`/`javascript:`/`data:`) is rejected even when the host is on the whitelist.

### Tier 1 — exact host match

Used for parents with broad attack surface where suffix matching could let a subdomain takeover or open redirect pivot through this WebView.

| Host | Reason |
|---|---|
| `cursor.com`, `www.cursor.com`, `authenticator.cursor.sh`, `authenticate.cursor.sh` | Cursor primary |
| `accounts.google.com`, `oauth2.googleapis.com` | Google OAuth (well-known endpoints only) |
| `github.com`, `api.github.com` | GitHub OAuth (no `pages.github.com` / `gist.github.com`) |
| `js.stripe.com`, `m.stripe.network` | Cursor dashboard payment widgets |
| `api.workos.com` | WorkOS non-tenant API |
| `login.microsoftonline.com` | Azure AD entry |

### Tier 1 — Google OAuth ccTLD redirects

Google routes some users through `accounts.google.<ccTLD>` (for example `accounts.google.co.kr`) before landing on `accounts.google.com`. Without these entries the WebView blocks the locale hop, forcing Google's fallback path and adding user-visible friction.

We list `accounts.google.<ccTLD>` for the top ~50 markets only. This is intentionally narrow: only the `accounts` subdomain is covered, so locale variants of `sites`, `mail`, `pages`, etc. remain blocked. The list is maintained reactively — file an issue if a missing country triggers a block.

Background: Google announced in April 2025 that it is phasing out ccTLDs in favor of unified `.com` routing, so this list is expected to shrink in relevance over time.

### Tier 2 — suffix match

Used only where exact enumeration is impractical (internal Cursor service segmentation, tenant-scoped SSO).

| Suffix | Reason |
|---|---|
| `.cursor.com`, `.cursor.sh` | Internal segmentation |
| `.workos.com` | Tenant-scoped SSO connections |
| `.microsoftonline.com` | Azure AD tenant variability |

### Mitigations in place

- `WKWebsiteDataStore.nonPersistent()` — login WebView leaves no on-disk cookie / cache
- `javaScriptCanOpenWindowsAutomatically = false`
- WebView is opened only for login and torn down immediately on completion
- Host check is case-insensitive
- Both `navigationAction` and `navigationResponse` enforce the same whitelist

### Cookie capture validation

Before persisting cookies to Keychain, `captureAndComplete` verifies that all names in `requiredCookieNames` are present. This blocks partial-cookie-write races where non-auth cookies (CSRF, analytics) arrive before the session token, which would otherwise produce a "successful" capture with an empty session header.

### Accepted residual risk

Subdomain takeover of an entity under one of the Tier 2 suffix providers (e.g. an unmaintained `*.workos.com` tenant) could in principle reach the login WebView. The blast radius is limited to a single Cursor login session; we accept this risk in exchange for supporting tenant-scoped SSO without an unbounded enumeration burden.

### Authentication features unsupported in WebView

The login WebView is a `WKWebView` in an ad-hoc-signed app, not a full system browser. The following Google account features rely on entitlements (`com.apple.developer.web-browser`, associated domains, iCloud Keychain passkey access) that are only granted to paid Apple Developer Program members and do not work here:

- **Passkey / WebAuthn** (Bluetooth or platform authenticator)
- **Cross-device sign-in** that depends on iCloud Keychain passkey sync

Affected users should fall back to password + 2FA, an emailed verification code, or an alternative provider (GitHub, email link). This is a constraint of the build signature, not a CursorMeter design choice; the same applies to other ad-hoc-signed macOS apps that embed Google OAuth in a WebView. See also the related Keychain Data Protection limitation tracked in the project issue tracker.

## Out of Scope

- Vulnerabilities in upstream dependencies (Cursor, Apple SDKs, OAuth providers) — please report to the respective vendor
- Issues that require physical access to an unlocked Mac
- Speculative timing attacks against the local Keychain
