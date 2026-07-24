# Weekly Chart on Personal Accounts (#103) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the weekly usage chart on personal (free/pro/…) Cursor accounts by calling `get-filtered-usage-events` with `teamId: 0` and no `userId`, instead of hiding it for every non-enterprise account.

**Architecture:** Three-way branch in `UsageViewModel.refreshWeeklyChart` on `membershipType` (enterprise → existing team path; nil → hide; anything else → direct personal fetch). `isEnterpriseTeam` is renamed to `weeklyChartAvailable` (its real meaning). A new `WeeklyMode` cache generalizes the optimistic parallel fetch to both paths.

**Tech Stack:** Swift 6 strict concurrency, pure AppKit, zero external dependencies, XCTest + MockURLProtocol.

**Spec:** `docs/superpowers/specs/2026-07-24-weekly-chart-personal-design.md` (rev 2, Codex-reviewed)

## Global Constraints

- Swift 6 strict concurrency: `@MainActor` view model, `Sendable` models. CI (Xcode 16.4) is stricter than local — see CLAUDE.md Conventions.
- Zero external dependencies — macOS SDK only.
- Commit format: `[#103] <type>: description`.
- Tests must never call `UNUserNotificationCenter.current()` or touch the real Keychain — use the `UsageViewModel` seams (`init(apiClient:)` + MockURLProtocol, `keychainDeleteHandler`, `sessionExpiredNotifier`, `testHook_*`).
- New/renamed `@Observable` state read by UI MUST be inside the `withObservationTracking` blocks in `CursorMeterApp` — otherwise UI silently never updates.
- Run `swift test` after every task; all tests must pass before commit.
- `swift test` runs macOS unified logging under the same subsystem — ignore log noise.

---

### Task 1: API layer — optional `userId` in the weekly fetch

**Files:**
- Modify: `Sources/CursorMeter/CursorAPIClient.swift:74-96` (`fetchWeeklyUsage`)
- Modify: `Sources/CursorMeter/UsageViewModel.swift:878-908` (`collectWeeklyEvents` signature passthrough)
- Test: `Tests/CursorMeterTests/WeeklyUsageTests.swift`

**Interfaces:**
- Consumes: existing `CursorAPIClient.performRequest` (unchanged).
- Produces: `fetchWeeklyUsage(cookieHeader:teamId:userId:page:pageSize:)` where `userId: Int?` — when nil, the `userId` key is ABSENT from the JSON body (not null). `collectWeeklyEvents(apiClient:cookieHeader:teamId:userId:pageSize:maxPages:today:calendar:)` likewise takes `userId: Int?`. Task 3 calls `collectWeeklyEvents(teamId: 0, userId: nil, ...)`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CursorMeterTests/WeeklyUsageTests.swift`, next to `testFetchWeeklyUsageSendsOriginAndBody` (line ~511):

```swift
    func testFetchWeeklyUsageOmitsUserIdWhenNil() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = """
            { "totalUsageEventsCount": 0, "usageEventsDisplay": [] }
            """
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        _ = try await client.fetchWeeklyUsage(
            cookieHeader: "session=x",
            teamId: 0,
            userId: nil,
            page: 1,
            pageSize: 50
        )

        let request = try XCTUnwrap(captured)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: Any])
        XCTAssertEqual(parsed["teamId"] as? Int, 0)
        XCTAssertFalse(parsed.keys.contains("userId"), "nil userId must omit the key entirely (verified live: server accepts absent key)")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WeeklyUsageTests/testFetchWeeklyUsageOmitsUserIdWhenNil`
Expected: COMPILE FAILURE — "'Int' is not convertible to expected argument type" (current signature is `userId: Int`). A compile failure at the callsite is this step's red state.

- [ ] **Step 3: Make `userId` optional in both signatures**

In `Sources/CursorMeter/CursorAPIClient.swift`, replace the body-construction of `fetchWeeklyUsage`:

```swift
    func fetchWeeklyUsage(
        cookieHeader: String,
        teamId: Int,
        userId: Int?,
        page: Int,
        pageSize: Int = 100
    ) async throws -> FilteredUsageEventsResponse {
        // Personal accounts (teamId 0) omit userId entirely — the server scopes
        // events to the session cookie. Sending "userId": null is unverified;
        // absent key is the shape confirmed live (#103).
        var bodyDict: [String: Any] = [
            "teamId": teamId,
            "page": page,
            "pageSize": pageSize,
        ]
        if let userId {
            bodyDict["userId"] = userId
        }
```

(rest of the method unchanged).

In `Sources/CursorMeter/UsageViewModel.swift` `collectWeeklyEvents` (line ~878), change only the parameter type:

```swift
    nonisolated static func collectWeeklyEvents(
        apiClient: CursorAPIClient,
        cookieHeader: String,
        teamId: Int,
        userId: Int?,
        pageSize: Int,
        maxPages: Int,
        today: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> [UsageEvent] {
```

Body is unchanged — it already just forwards `userId` to `fetchWeeklyUsage`.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS (existing callers pass non-nil `Int`, which coerces to `Int?`; existing body-shape test still asserts `userId == 232352588` when provided).

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/CursorAPIClient.swift Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/WeeklyUsageTests.swift
git commit -m "[#103] feat: fetchWeeklyUsage accepts nil userId (key omitted from body)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Rename `isEnterpriseTeam` → `weeklyChartAvailable` + observation fixes

Pure rename plus two observation-block lines. No behavior change; the full existing suite is the safety net.

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift` (declaration ~line 216-221 + every use: `applyOptimisticWeekly`, `refreshWeeklyChart`, `resetPerAccountState`, `logout`)
- Modify: `Sources/CursorMeter/MenuBarView.swift:524`
- Modify: `Sources/CursorMeter/SettingsAppearanceTabViewController.swift:81`
- Modify: `Sources/CursorMeter/CursorMeterApp.swift:424` (observePopover) and `:316-318` (observeSettings)
- Modify: any test files referencing `isEnterpriseTeam`

**Interfaces:**
- Produces: `UsageViewModel.weeklyChartAvailable: Bool` — true iff a weekly fetch succeeded for the active account. Tasks 3-4 set/clear it; MenuBarView and Settings gate on it.

- [ ] **Step 1: Enumerate occurrences**

Run: `grep -rn "isEnterpriseTeam" Sources/ Tests/`
Expected: hits in `UsageViewModel.swift` (~7), `MenuBarView.swift` (1), `SettingsAppearanceTabViewController.swift` (1), `CursorMeterApp.swift` (1), plus test files. Note the count.

- [ ] **Step 2: Mechanical rename**

Run:

```bash
grep -rl "isEnterpriseTeam" Sources/ Tests/ | xargs sed -i '' 's/isEnterpriseTeam/weeklyChartAvailable/g'
```

Then update the doc comment at the declaration (`Sources/CursorMeter/UsageViewModel.swift` ~line 217) to match the new semantics:

```swift
    /// True when a weekly fetch succeeded for the active account (enterprise
    /// team path or personal teamId-0 path, #103). Gates the popover chart and
    /// the Settings weekly-chart section.
    var weeklyChartAvailable: Bool = false
```

- [ ] **Step 3: Add the Settings observation line**

In `Sources/CursorMeter/CursorMeterApp.swift` `observeSettings()` (line ~316), the tracking block currently reads only `activeAuthSource`. Add the availability read so an open Settings window re-renders when the flag flips (Codex review finding):

```swift
    private func observeSettings() {
        withObservationTracking {
            _ = viewModel.activeAuthSource
            // #103: weekly-chart section visibility keys on availability; an
            // open Settings window must react when it flips.
            _ = viewModel.weeklyChartAvailable
        } onChange: { [weak self] in
```

(`observePopover` needs no addition — the sed rename already updated its existing `_ = viewModel.isEnterpriseTeam` line in place, keeping it tracked.)

- [ ] **Step 4: Verify rename completeness and run suite**

Run: `grep -rn "isEnterpriseTeam" Sources/ Tests/ && echo "STALE NAME REMAINS" || echo CLEAN`
Expected: `CLEAN`

Run: `swift test`
Expected: PASS (rename is behavior-neutral).

- [ ] **Step 5: Commit**

```bash
git add -A Sources/ Tests/
git commit -m "[#103] refactor: rename isEnterpriseTeam -> weeklyChartAvailable; track it in observeSettings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Personal path in `refreshWeeklyChart` (three-way membership branch)

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift:930-990` (`refreshWeeklyChart` → split into enterprise/personal helpers)
- Test: `Tests/CursorMeterTests/WeeklyUsageTests.swift`

**Interfaces:**
- Consumes: `collectWeeklyEvents(..., userId: Int?)` from Task 1; `weeklyChartAvailable` from Task 2.
- Produces: `refreshWeeklyChartPersonal(cookieHeader:)` — Task 4 adds mode-cache writes inside both path helpers.

- [ ] **Step 1: Write the failing tests**

Add a new test class to `Tests/CursorMeterTests/WeeklyUsageTests.swift` (bottom of file, before the closing helpers), driving the view model end-to-end like `CredentialChainTests` does:

```swift
@MainActor
final class PersonalWeeklyPathTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel() -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=t")
        vm.authState = .loggedIn
        return vm
    }

    /// Thread-safe accumulator for request paths + weekly bodies seen by the mock.
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        private var _weeklyBodies: [[String: Any]] = []
        func record(path: String) { lock.lock(); _paths.append(path); lock.unlock() }
        func record(weeklyBody: [String: Any]) { lock.lock(); _weeklyBodies.append(weeklyBody); lock.unlock() }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
        var weeklyBodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _weeklyBodies }
    }

    /// Full API surface for a free personal account. Weekly endpoint behavior
    /// is injectable so failure cases reuse the same handler.
    private static func freeAccountHandler(
        log: RequestLog,
        weeklyStatus: Int = 200
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let url = request.url!
            log.record(path: url.path)
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage-summary":
                let json = """
                {"billingCycleStart":"2026-07-15T03:23:58.561Z","billingCycleEnd":"2026-08-15T03:23:58.561Z",
                 "membershipType":"free","limitType":"user","isUnlimited":false,
                 "autoModelSelectedDisplayMessage":"You've used 3% of your included total usage",
                 "individualUsage":{"plan":{"enabled":true,"used":0,"limit":0,"remaining":0,"totalPercentUsed":2.5},
                                    "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},
                 "teamUsage":{}}
                """
                return (ok, Data(json.utf8))
            case "/api/auth/me":
                return (ok, Data("{\"email\":\"p@gmail.com\",\"name\":\"P\"}".utf8))
            case "/api/usage":
                return (ok, Data("{\"gpt-4\":{\"numRequests\":0,\"numRequestsTotal\":0,\"numTokens\":0,\"maxTokenUsage\":null,\"maxRequestUsage\":null},\"startOfMonth\":\"2026-07-15T03:23:58.561Z\"}".utf8))
            case "/api/dashboard/get-filtered-usage-events":
                if let parsed = try? JSONSerialization.jsonObject(with: WeeklyUsageTests.bodyData(from: request)) as? [String: Any] {
                    log.record(weeklyBody: parsed)
                }
                guard weeklyStatus == 200 else {
                    return (HTTPURLResponse(url: url, statusCode: weeklyStatus, httpVersion: nil, headerFields: nil)!, Data())
                }
                let nowMs = Int(Date().timeIntervalSince1970 * 1000)
                let json = """
                {"totalUsageEventsCount":1,"usageEventsDisplay":[
                  {"timestamp":"\(nowMs)","requestsCosts":1.1,
                   "kind":"USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION","chargedCents":4.5}]}
                """
                return (ok, Data(json.utf8))
            default:
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
        }
    }

    func testFreePlanFetchesWeeklyWithTeamZeroAndNoTeamDiscovery() async throws {
        let vm = makeViewModel()
        let log = RequestLog()
        MockURLProtocol.requestHandler = Self.freeAccountHandler(log: log)

        await vm.refresh()

        XCTAssertTrue(vm.weeklyChartAvailable)
        XCTAssertEqual(vm.weeklyData?.count, 7)
        let body = try XCTUnwrap(log.weeklyBodies.first)
        XCTAssertEqual(body["teamId"] as? Int, 0)
        XCTAssertFalse(body.keys.contains("userId"))
        XCTAssertFalse(log.paths.contains("/api/dashboard/teams"),
                       "personal path must not discover teams")
        XCTAssertFalse(log.paths.contains("/api/dashboard/get-team-spend"),
                       "personal path must not fetch the roster")
    }

    func testNilMembershipSkipsWeeklyEntirely() async {
        let vm = makeViewModel()
        let log = RequestLog()
        let base = Self.freeAccountHandler(log: log)
        // Summary 500s -> legacy usage-only fallback -> membershipType nil.
        MockURLProtocol.requestHandler = { request in
            if request.url!.path == "/api/usage-summary" {
                log.record(path: request.url!.path)
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return try base(request)
        }

        await vm.refresh()

        XCTAssertNotNil(vm.usageData, "legacy fallback still renders usage")
        XCTAssertNil(vm.usageData?.membershipType)
        XCTAssertFalse(vm.weeklyChartAvailable)
        XCTAssertFalse(log.paths.contains("/api/dashboard/get-filtered-usage-events"),
                       "nil membership = summary failed; plan unknown, no teamId-0 guess")
    }

    func testPersonalWeeklyFailureWithoutPriorDataHidesChart() async {
        let vm = makeViewModel()
        let log = RequestLog()
        MockURLProtocol.requestHandler = Self.freeAccountHandler(log: log, weeklyStatus: 500)

        await vm.refresh()

        XCTAssertFalse(vm.weeklyChartAvailable)
        XCTAssertNil(vm.weeklyData)
    }

    func testPersonalWeeklyTransientFailureRetainsStaleChart() async {
        let vm = makeViewModel()
        let log = RequestLog()
        MockURLProtocol.requestHandler = Self.freeAccountHandler(log: log)
        await vm.refresh()
        XCTAssertEqual(vm.weeklyData?.count, 7)

        MockURLProtocol.requestHandler = Self.freeAccountHandler(log: log, weeklyStatus: 500)
        await vm.refresh()

        XCTAssertEqual(vm.weeklyData?.count, 7, "stale chart retained on transient failure")
        XCTAssertTrue(vm.weeklyChartAvailable, "availability survives transient failure with prior data")
    }
}
```

Note: `bodyData(from:)` is currently `private static` in `WeeklyUsageTests` — change its access to `static` (drop `private`) so the new class reuses it. Do that in this step.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PersonalWeeklyPathTests`
Expected: FAIL — `testFreePlanFetchesWeeklyWithTeamZeroAndNoTeamDiscovery` asserts `weeklyChartAvailable == true` but the current guard hides the chart for non-enterprise (`XCTAssertTrue failed`). `testNilMembershipSkipsWeeklyEntirely`, `testPersonalWeeklyFailureWithoutPriorDataHidesChart` may already pass (today everything non-enterprise hides) — that's fine; the first and last must fail.

- [ ] **Step 3: Implement the three-way branch**

In `Sources/CursorMeter/UsageViewModel.swift`, replace `refreshWeeklyChart` (line ~930). The existing body from `guard let teamId = ...` through the final `catch` block moves verbatim into `refreshWeeklyChartEnterprise`:

```swift
    private func refreshWeeklyChart(
        cookieHeader: String,
        data: UsageDisplayData,
        userInfo: UserInfoResponse
    ) async {
        // nil membershipType = usage-summary failed (legacy fallback), which
        // says nothing about the plan — an enterprise account mid-outage must
        // not be routed to the personal teamId-0 path (#103 Codex review).
        guard let membership = data.membershipType?.lowercased() else {
            weeklyChartAvailable = false
            weeklyData = nil
            return
        }
        if membership == "enterprise" {
            await refreshWeeklyChartEnterprise(cookieHeader: cookieHeader, userInfo: userInfo)
        } else {
            await refreshWeeklyChartPersonal(cookieHeader: cookieHeader)
        }
    }

    private func refreshWeeklyChartEnterprise(
        cookieHeader: String,
        userInfo: UserInfoResponse
    ) async {
        // ... existing body verbatim, from `guard let teamId = await resolveTeamId`
        // through the trailing catch block ...
    }

    /// Personal accounts: the events endpoint accepts teamId 0 with no userId
    /// and scopes to the session cookie (verified live 2026-07-24, free plan).
    /// No team/roster discovery — two fewer round-trips than enterprise.
    private func refreshWeeklyChartPersonal(cookieHeader: String) async {
        do {
            let events = try await Self.collectWeeklyEvents(
                apiClient: apiClient,
                cookieHeader: cookieHeader,
                teamId: 0,
                userId: nil,
                pageSize: Self.weeklyPageSize,
                maxPages: Self.weeklyMaxPages
            )
            weeklyData = events.sevenDayRolling(today: Date(), calendar: .current)
            weeklyChartAvailable = true
        } catch APIError.forbidden {
            Log.info("Personal weekly fetch returned 403 — hiding chart")
            weeklyChartAvailable = false
            weeklyData = nil
        } catch {
            Log.info("Personal weekly fetch failed: \(error.localizedDescription)")
            if weeklyData == nil {
                weeklyChartAvailable = false
            }
        }
    }
```

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS. Watch specifically for `CredentialChainTests` — its `successHandler` returns `membershipType: "pro"`, so those refreshes now attempt the personal weekly fetch and hit the handler's 404 default arm → graceful hide, assertions unaffected. If any of them fail on an unexpected request, extend that handler's default arm, not the production code.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/WeeklyUsageTests.swift
git commit -m "[#103] feat: weekly chart on personal accounts via teamId 0 (no team/roster discovery)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `WeeklyMode` cache — optimistic parallel fetch for both paths

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift` (`makeOptimisticWeeklyTask` ~line 806, `applyOptimisticWeekly` ~line 911, both path helpers from Task 3, `resetPerAccountState` ~line 473, `logout` ~line 1010)
- Test: `Tests/CursorMeterTests/WeeklyUsageTests.swift` (`PersonalWeeklyPathTests`)

**Interfaces:**
- Consumes: Task 3's path helpers.
- Produces: `UsageViewModel.WeeklyMode` (internal enum, `Equatable`, `Sendable`): `.enterprise(teamId: Int, userId: Int)` / `.personal`; `internal private(set) var cachedWeeklyMode: WeeklyMode?` (internal for `@testable` assertions, matching existing seam style).

- [ ] **Step 1: Write the failing tests**

Add to `PersonalWeeklyPathTests`:

```swift
    func testPersonalSuccessCachesWeeklyModeAndLogoutClearsIt() async {
        let vm = makeViewModel()
        let log = RequestLog()
        MockURLProtocol.requestHandler = Self.freeAccountHandler(log: log)

        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)

        vm.logout()
        XCTAssertNil(vm.cachedWeeklyMode, "logout clears the weekly mode cache")
    }

    func testAccountSwitchClearsWeeklyMode() async {
        let vm = makeViewModel()
        let log = RequestLog()
        MockURLProtocol.requestHandler = Self.freeAccountHandler(log: log)
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)

        // Same shape, different email, weekly now failing: the switch must
        // clear the cached mode, and the failed re-discovery must not restore it.
        let base = Self.freeAccountHandler(log: log, weeklyStatus: 500)
        MockURLProtocol.requestHandler = { request in
            if request.url!.path == "/api/auth/me" {
                let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (ok, Data("{\"email\":\"other@gmail.com\",\"name\":\"O\"}".utf8))
            }
            return try base(request)
        }
        await vm.refresh()

        XCTAssertNil(vm.cachedWeeklyMode)
        XCTAssertNil(vm.weeklyData, "no cross-account weekly leak (#54)")
    }

    func testPersonal403ClearsWeeklyModeAndHidesChart() async {
        let vm = makeViewModel()
        let log = RequestLog()
        MockURLProtocol.requestHandler = Self.freeAccountHandler(log: log)
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)

        MockURLProtocol.requestHandler = Self.freeAccountHandler(log: log, weeklyStatus: 403)
        await vm.refresh()

        XCTAssertNil(vm.cachedWeeklyMode)
        XCTAssertFalse(vm.weeklyChartAvailable)
        XCTAssertNil(vm.weeklyData)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PersonalWeeklyPathTests`
Expected: COMPILE FAILURE — `cachedWeeklyMode` / `WeeklyMode` don't exist yet.

- [ ] **Step 3: Implement the mode cache**

In `Sources/CursorMeter/UsageViewModel.swift`:

a) Declare the enum + cache near the other caches (next to `cachedTeamId`):

```swift
    /// Which weekly-fetch shape succeeded last for the active account. Drives
    /// the optimistic parallel fetch on subsequent refreshes (#103). Internal
    /// (not private) so tests can assert invalidation; never mutated outside
    /// this file.
    enum WeeklyMode: Equatable, Sendable {
        case enterprise(teamId: Int, userId: Int)
        case personal
    }
    @ObservationIgnored internal private(set) var cachedWeeklyMode: WeeklyMode?
```

b) Rewrite `makeOptimisticWeeklyTask` to key on the mode:

```swift
    /// Returns an optimistic weekly task only when a prior refresh established
    /// the fetch shape for this account — otherwise the sequential path inside
    /// `refreshWeeklyChart` discovers it first.
    private func makeOptimisticWeeklyTask(
        cookieHeader: String
    ) -> Task<[DayUsage], Error>? {
        guard let mode = cachedWeeklyMode else { return nil }
        let apiClient = self.apiClient
        let pageSize = Self.weeklyPageSize
        let maxPages = Self.weeklyMaxPages
        let teamId: Int
        let userId: Int?
        switch mode {
        case let .enterprise(cachedTeam, cachedUser):
            teamId = cachedTeam
            userId = cachedUser
        case .personal:
            teamId = 0
            userId = nil
        }
        return Task {
            try await Self.collectWeeklyEvents(
                apiClient: apiClient,
                cookieHeader: cookieHeader,
                teamId: teamId,
                userId: userId,
                pageSize: pageSize,
                maxPages: maxPages
            ).sevenDayRolling(today: Date(), calendar: .current)
        }
    }
```

c) Set the mode on success in both path helpers:
- `refreshWeeklyChartEnterprise`: in the success branch (right after `weeklyChartAvailable = true`), add `cachedWeeklyMode = .enterprise(teamId: teamId, userId: userId)`.
- `refreshWeeklyChartPersonal`: after `weeklyChartAvailable = true`, add `cachedWeeklyMode = .personal`.

d) Clear the mode on every invalidation point (spec list):
- `refreshWeeklyChartEnterprise` 403 catch arm (alongside `cachedTeamId = nil` etc.): `cachedWeeklyMode = nil`
- `refreshWeeklyChartPersonal` 403 catch arm: `cachedWeeklyMode = nil`
- `applyOptimisticWeekly` 403 catch arm: `cachedWeeklyMode = nil`
- `resetPerAccountState()`: `cachedWeeklyMode = nil`
- `logout()` (next to `cachedTeamId = nil`): `cachedWeeklyMode = nil`

`applyOptimisticWeekly` success arm needs no mode write — an optimistic task only exists when the mode is already cached and unchanged.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS, including the three new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/WeeklyUsageTests.swift
git commit -m "[#103] feat: WeeklyMode cache — optimistic parallel weekly fetch for personal accounts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation refresh

**Files:**
- Modify: `docs/API_REFERENCE.md` (`get-filtered-usage-events` section, `dashboard/teams` section, `usage-summary` section, "Known limitations")
- Modify: `Sources/CursorMeter/WeeklyUsageModels.swift:5-7` (header comment says "enterprise team accounts")

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `docs/API_REFERENCE.md`**

Four edits:

1. In the `POST /api/dashboard/get-filtered-usage-events` section, change the intro line "(enterprise team accounts only)" to "(all account types)" and add after the Body line:

```markdown
- **Personal accounts** (free verified live 2026-07-24; pro assumed): pass `teamId: 0` and omit `userId` entirely — events are scoped to the session cookie. Observed personal-plan event fields: `kind: "USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION"`, `customSubscriptionName: "free"`, fractional `requestsCosts` (e.g. 1.1), numeric `owningUser` present in each event.
```

2. In the `POST /api/dashboard/teams` section, delete the stale line "`GET`, no body. Empty / non-200 on personal plans → CursorMeter treats the account as non-enterprise and hides the weekly chart." and replace with: "Empty / non-200 on personal plans; observed `{}` (no `teams` key) on a free account 2026-07-24. Personal accounts skip this endpoint entirely for the weekly chart (#103)."

3. In the `GET /api/usage-summary` section, append the observed free-plan shape:

```markdown
**Free plan** (observed 2026-07-24): `membershipType: "free"`, `plan: {enabled, used: 0, limit: 0, remaining: 0, breakdown: {included, bonus, total}, autoPercentUsed, apiPercentUsed, totalPercentUsed}`, `onDemand: {enabled: false, limit: null}`, `teamUsage: {}`. CursorMeter renders this via percent-only mode (`totalPercentUsed`). Note the dashboard message and the numeric fields can disagree (message "3%", `autoPercentUsed: 5`, `totalPercentUsed: 2.5`) — the app displays `totalPercentUsed`.
```

4. In "Known limitations / open questions", update the first bullet ("Personal Pro / Free plan compatibility … unverified") to: "**Personal Pro/Pro+ weekly events** — `teamId: 0` verified on free only; pro assumed identical. Failure degrades to a hidden chart."

- [ ] **Step 2: Update the models header comment**

`Sources/CursorMeter/WeeklyUsageModels.swift` line 5-7:

```swift
/// Per-event usage stream from Cursor's dashboard backend. Used by the weekly
/// bar graph (enterprise team + personal accounts, #103). See
/// `docs/API_REFERENCE.md` for the request shape and the Origin-header requirement.
```

- [ ] **Step 3: Build (comment-only Swift change) and commit**

Run: `swift build`
Expected: success.

```bash
git add docs/API_REFERENCE.md Sources/CursorMeter/WeeklyUsageModels.swift
git commit -m "[#103] docs: API reference — teamId 0 personal events, free usage-summary shape, stale teams note

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Live verification, push, CI, close

**Files:** none (verification + release hygiene).

- [ ] **Step 1: Full suite**

Run: `swift test`
Expected: PASS, 0 failures. Paste the summary line.

- [ ] **Step 2: Reinstall and live-verify on the real free account**

The dev machine's Cursor IDE is signed into a free personal account — the app connects via the IDE credential automatically. Follow CLAUDE.md reinstall sequence:

```bash
pkill -9 -x CursorMeter
rm -rf /Applications/CursorMeter.app
bash Scripts/package_app.sh
cp -r CursorMeter.app /Applications/
open /Applications/CursorMeter.app
```

Then AX-verify (element paths only, never coordinates — CLAUDE.md):

1. Open the popover via `menu bar item 1 of menu bar 1` (retry-loop; status-item click toggles).
2. Confirm the weekly chart renders (chart view present under the popover AX tree, height 76).
3. Open Settings → Display tab → confirm the weekly-chart style section is visible.
4. `/usr/bin/log show --predicate 'subsystem == "com.cursormeter" AND process == "CursorMeter"' --info --debug --last 5m` — confirm no weekly-fetch error lines.

This is the manual observation-tracking verification the spec requires (popover re-render + Settings section on a personal account).

- [ ] **Step 3: Push and watch CI**

```bash
git push origin main
gh run list --limit 1
```

Expected: Test workflow green. If red, fix before anything else (CI-blocker rule).

- [ ] **Step 4: Close the issue**

```bash
gh issue close 103 --comment "Shipped: weekly chart now renders on personal accounts (teamId 0, no userId). Enterprise path unchanged. Live-verified on a free account; docs/API_REFERENCE.md updated."
gh issue list --state open
```

Show the remaining open issues to the user (post-close check, CLAUDE.md).

---

## Self-Review Notes

- Spec coverage: scope decision → Task 3 Step 3 guard; API signature → Task 1; rename + observeSettings → Task 2; mode cache + invalidation points (reset/logout/403) → Task 4; failure-semantics pinning → Task 3 tests 3-4; teams/roster-skip URL assertion → Task 3 test 1; nil-membership test → Task 3 test 2; logout/switch cache tests → Task 4; manual AX verification → Task 6 Step 2; docs → Task 5. No gaps found.
- Naming consistency: `weeklyChartAvailable`, `cachedWeeklyMode`, `WeeklyMode`, `refreshWeeklyChartEnterprise/Personal`, `collectWeeklyEvents(userId: Int?)` used consistently across tasks.
- Known accepted risks (spec): pro/pro+ unverified (graceful hide), email-nil switch limitation (pre-existing).
