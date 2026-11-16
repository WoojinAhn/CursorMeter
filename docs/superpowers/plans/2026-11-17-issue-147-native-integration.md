# Shared Weekly Usage Native Integration Plan

> **For agentic workers:** Use superpowers:subagent-driven-development task by task, with specification review before quality review. Coordinator owns shared documentation and commits.

**Goal:** Show shared weekly usage and prepaid consumption in the existing dual meter using CursorMeter's existing Cursor authentication, and verify a local development app.

**Architecture:** Keep Cursor IDE connection, captured browser login, Keychain storage, credential fallback and session ownership unchanged. Read the official Cursor DashboardService with the same selected credential. Detect the shared weekly regime from GetPlanInfo, keep shared values distinct from legacy monthly values, and reuse the existing outer ring/inner fill presentation. No Grok login, browser-cookie extraction, CLI authentication dependency, or model inference is introduced.

**Tech Stack:** Swift 6, Foundation URLSession, AppKit, XCTest; no external dependencies.

**Baseline:** feature/147-shared-usage, 76ad636; fetched origin/main remains efe90d0. Existing foundation has 1165 passing tests. Issue #147 and docs/design-147-shared-usage.md define the approved composition.

## Verified transport and boundaries

Read-only requests using the existing IDE access token returned HTTP 200 on the four required official bundled Cursor CLI methods at `https://api2.cursor.sh/aiserver.v1.DashboardService/`: GetPlanInfo with `{}`, GetCurrentPeriodUsage with `{"personalScope":true}`, GetUserPrepaidBilling with `{}`, and GetHardLimit with `{"personalScope":true}`. A separate GetMonthlyBillingCycle request with `{}` also succeeded for research. Use Bearer authorization, application/json and Connect-Protocol-Version: 1. No team header is supplied for this personal scope. The existing cursor.com auth/me and usage-summary calls also still succeed.

GetPlanInfo returned isMerged true and planInfo.includedUsagePeriod INCLUDED_USAGE_PERIOD_WEEKLY. Current-period planUsage.totalPercentUsed and billingCycleStart/End match the weekly period; includedUsageResetsAt agrees. Do not use the legacy summary's monthly percentages for this regime. GetMonthlyBillingCycle is the subscription billing cycle and is NOT the calendar month of spentThisMonthCents.

Prepaid returns billingMode, eligible, availableCents, fundedCents, spentCents, optional spentThisMonthCents, optional autoTopUp, and topUps. Int64 protobuf JSON values are decimal strings; nonoptional proto3 zeros can be omitted. Top-up amounts here are positive, unlike the raw Grok ledger. Read only; never call a payment mutation. Confirmed charge pricing can be sub-cent while the balance remains integer cents; never calculate a replacement server balance by subtracting event prices.

Personal scope only. Unsupported merged scopes must remain explicit, and cannot silently fall back to legacy percentages. Account/credential generation gates own every accepted snapshot. RPC failure is not an authority to erase otherwise valid Cursor credentials. Existing browser login remains available; unsupported cookie formats only make this enrichment unavailable.

## Task 1: Dashboard wire models and client

Files: new CursorSharedAPIClient.swift and CursorSharedUsageModels.swift; new corresponding test files; minimal CurrentPeriodPlanUsage.totalPercentUsed addition in SplitUsageModels.swift if reused.

- [x] Write failing tests for existing-cookie Bearer extraction, exact RPC URL/body/headers, redirect rejection, bounded response, invalid credentials without a request, and 401/403/network/decode distinctions.
- [x] Implement a separate ephemeral URLSession client with fixed read-only RPC paths. Extract exactly one WorkosCursorSessionToken, decode its value once, validate the user-prefix/JWT shape, and send only the JWT to api2.cursor.sh. Never forward cookies or authorization on redirects and never log credentials or response bodies.
- [x] Add fixtures for explicit shared weekly versus legacy/unsupported plans; optional totalPercentUsed zero versus missing; valid matching weekly reset and malformed dates; prepaid missing/zero/malformed values; top-up success/pending/failure/duplicates/unknown origins.
- [x] Normalize canonical protobuf Int64 string amounts exactly as Decimal. Numeric JSON compatibility uses Foundation Decimal precision; malformed fractional literals beyond that precision are outside this compatibility contract, and do not justify a separate arbitrary-precision JSON parser. Expose balance independently. A purchased-credit denominator requires a reconciled funded/spent/available equation AND a complete matching set of distinct succeeded purchase records. Only TOPUP_MANUAL is currently verified; unknown automatic origins, conflicting records, grants, refunds, and unreconciled evidence leave the percentage unavailable. Do not assume a limited top-up array is complete. Preserve known balance and monthly spend if the ratio is unavailable.
- [x] Map GetHardLimit using the verified official bridge: explicit noUsageBasedAllowed or hardLimit <= 0 means a zero cap; hardLimit >= 2147483647 means no cap; other valid values are whole dollars converted to cents. Missing/malformed remains unknown. Auto Top-up's monthlyCapCents is a purchase cap, never a monthly consumed-usage cap. Missing rule means unknown. Do not assign the subscription billing date as the paid-month reset.
- [x] Run focused tests, independent spec review, then quality review. Commit only reviewed files with issue/Codex attribution.

Critical examples remain `PrepaidCreditUsage(remainingCents:1240,totalPurchasedCents:2000).percentUsed == 38` and a replenishment to 3240/4000 yielding19; invalid or unknown purchase coverage retains the balance with a nil ratio.

Task 1 completed at `6f8b1a5` after independent specification and quality review. Initial full regression: 1190/0; final correction-focused root verification: 44/0. Canonical Int64 strings remain exact, with the numeric compatibility limit described above.

## Task 2: Existing-session refresh integration

Files: new SharedUsageController.swift and tests; surgical UsageViewModel.swift integration; test factory injection only as needed.

- [x] Add session-owned shared mode/snapshot/error state with injected provider and deterministic tests before implementation.
- [x] Resolve plan mode within the accepted credential/identity refresh. Bind every result to the existing generation, credential and personal scope. Preserve the legacy refresh path for non-merged accounts. Do not add another login, credential store or account-selection system.
- [x] Fetch current-period and prepaid independently once shared mode is known; retain independent valid readings on partial failure and mark stale data. A failed known-shared refresh cannot resurrect monthly percentages.
- [x] Clear shared state on logout, credential/account changes and unsupported scope. Discard late success/error/401 from retired generations. Prevent shared snapshots from entering legacy monthly alerts, jump detection, split estimates, chart/cache collection, or on-demand latches.
- [x] Test mode detection, partial failure/recovery, unknown versus zero, rollover, logout/relogin races and legacy regression. Spec review then quality review.

Task 2 completed at `81bf6f4` after independent specification and quality review, including bounded re-reviews of profile failures and scope transitions. Coordinator full regression passed 1226/0 before the final quality corrections; final focused tests passed 38/0. The implementer also ran 122 related regression tests after those corrections. No login replacement or production UI wiring is part of this commit.

## Task 3: Existing dual-meter presentation

Files: MenuBarView.swift, CircularProgressIcon.swift, CursorMeterApp.swift and narrowly affected Settings controllers; shared UI/integration tests.

- [x] Reuse 300 pt popover, 112 pt outer ring/inner fill and right-side readings. Weekly always outside; prepaid consumption always inside. Keep neutral unknown/no-purchase/exhausted states distinct.
- [x] Preserve existing user/auth header and connection actions. Show remaining credit and verified purchased total; compact monthly spend/cap and auto-top-up metadata may show unavailable. Dashboard/manage-credit destinations open official pages without submitting billing changes.
- [x] Update all App observation blocks, tooltip/accessibility and menu-bar rendering for shared state. Preserve saved legacy display preferences; disable only controls whose monthly meaning is inapplicable. Keep recent/chart scope truthful rather than relabeling legacy data.
- [x] Verify synthetic AppKit layout and state transitions without real Keychain/notifications. Spec review then independent quality review.

Task 3 passed independent specification and quality review. Final UI copy corrections were included in a coordinator full regression of 1244 tests with zero failures. Synthetic native AppKit captures were inspected in light and dark appearances; four light captures document the shared popover and affected settings. Actual installed-app verification remains separate.

## Task 4: Integrated verification and local delivery

- [x] Run swift test and release build, then focused fixes/retests only when justified.
- [ ] Obtain final Argon High / Grok XHigh review through the already-requested rescue workflow; do not use prepaid Cursor inference for reviews.
- [x] Update API/design/security documentation and paired localized shared content together where affected. Preserve private billing evidence outside tracked files.
- [x] Inspect package/signing/install effects, preserve any explicitly selected signing identity, and package a dev app after remote freshness check. Back up an installed bundle before replacing it if installation is authorized.
- [ ] Verify the local app with the existing IDE login, fresh API values, visible native dual meter, refresh and account lifecycle. Capture affected screenshots with synthetic identity or cropped user information. Report source/test/build/installed-app evidence separately; keep unresolved cap/coverage semantics explicit.

Initial candidate `9856f8f` was packaged and installed with verified backups and matching executable hashes. The unchanged startup Keychain read is waiting for a macOS access grant, so native acceptance is still pending. Argon High approved the initial candidate; Grok XHigh requested two bounded corrections (explicit unsupported membership transitions and a neutral no-purchase track). The corrections passed independent specification and quality reviews, full regression (1,246/0), shared UI verification (15/0 after a fixture-only adjustment), and release build. Grok correction review remains pending; Argon correction review ended without an answer after a file-read permission denial and is not counted as a pass. No additional paid Cursor inference was used.
