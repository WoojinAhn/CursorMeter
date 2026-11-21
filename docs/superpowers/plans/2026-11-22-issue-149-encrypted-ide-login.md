# Encrypted Cursor IDE Login Recovery

## Objective and evidence

Restore the existing IDE login when Cursor stores its access token as a `cursor-safe-storage:v1:` envelope. Cursor 3.31.15's installed codec and a live metadata-only check establish the format mismatch. CursorMeter 604b2c2 currently treats the ciphertext as JWT and reports no session.

## Implementation contract

- Keep the read-only SQLite access-token source and plaintext compatibility. Decode only the verified bounded v1/v10 format using macOS CommonCrypto and Cursor Safe Storage. Validate identity and expiry after decoding.
- Query exact service `Cursor Safe Storage`, current account `Cursor Key`, then legacy `Cursor` only when appropriate. Never change access controls or modify Cursor's database. Retain a derived key in memory only; do not create a plaintext credential file.
- Startup, automatic refresh and availability checks cannot request authentication UI. A user-initiated Connect action may request one bounded authorization, remains responsive and ignores results retired by logout/session replacement.
- Distinguish encrypted credentials requiring authorization from an absent IDE session. Preserve the existing layout and reconnect action. Automatic availability polling cannot call an interactive path.
- Preserve browser fallback, logout suppression, account isolation and weekly/prepaid display contracts.

## Verification and delivery

1. Write failing synthetic ciphertext/reader/permission regressions, then implement. Tests must inject all credential and Keychain dependencies.
2. Cover valid plaintext/encrypted input, malformed/unknown payloads, wrong key, expiry/identity, current/legacy account lookup, denial, noninteractive background behavior, duplicate clicks and late authorization after logout.
3. Review the minimal before/after status mockup and native recovery state. Independently review the specification and final code, including the requested Argon High cross-check. Grok review was cancelled at the user's request; do not resume or use it as acceptance evidence.
4. Run full Swift tests and release build. Update four README languages and both security documents with the changed secret-access boundary.
5. Commit/push with issue reference, inspect CI, compare origin/main, then package with the selected existing local development identity. Back up the installed app/settings and verify the replacement's signature/hash.
6. Verify the real installed reconnect, existing IDE account and usage display. User handles any macOS authentication prompt directly. Record evidence in issue #149 without credentials or personal values.

No purchase, additional paid validation inference, merge, public release or issue closure is part of this fix.

## Recorded verification

- Synthetic regression tests demonstrated failures before implementation. The final full suite passed 1,341 tests with zero failures; the release build succeeded.
- Specification review and Argon High static review passed, including a focused re-review of the final legacy Keychain noninteractive policy. These reviews did not execute tests or read real credentials.
- The final background reader returned an available credential in a private read-only probe. A read-only API probe returned HTTP 200 from profile and usage-summary with matching normalized IDE identity. No credential values were logged. Installed-app validation is recorded separately in the issue.
