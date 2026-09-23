import XCTest
@testable import CursorMeter

@MainActor
final class WeeklyChartFreshnessTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel(withCapturedCookie: Bool = true) -> UsageViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(
            apiClient: CursorAPIClient(configuration: configuration),
            refreshFeedback: RefreshFeedback(timing: .immediate)
        )
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        vm.notificationEnabled = false
        vm.weeklyChartEnabled = true
        if withCapturedCookie {
            vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        }
        vm.authState = .loggedIn
        return vm
    }

    private static func handler(
        membership: String = "ultra",
        email: String = "user@example.com",
        weeklyStatus: Int = 200,
        summaryStatus: Int = 200,
        empty: Bool = false
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let url = request.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage-summary":
                if summaryStatus != 200 {
                    return (HTTPURLResponse(url: url, statusCode: summaryStatus, httpVersion: nil, headerFields: nil)!, Data())
                }
                let json = """
                {"membershipType":"\(membership)","limitType":"user","isUnlimited":false,
                 "individualUsage":{"plan":{"enabled":true,"used":10,"limit":2000,"remaining":1990,"totalPercentUsed":0.5}}}
                """
                return (ok, Data(json.utf8))
            case "/api/auth/me":
                return (ok, Data("{\"email\":\"\(email)\",\"name\":\"User\"}".utf8))
            case "/api/usage":
                return (ok, Data("{\"startOfMonth\":\"2026-09-01T00:00:00Z\"}".utf8))
            case "/api/dashboard/teams":
                return (ok, Data("{\"teams\":[{\"id\":77,\"name\":\"Team\"}]}".utf8))
            case "/api/dashboard/get-team-spend":
                return (ok, Data("{\"teamMemberSpend\":[{\"userId\":42,\"email\":\"\(email)\",\"hardLimitOverrideDollars\":null}]}".utf8))
            case "/api/dashboard/get-filtered-usage-events":
                if weeklyStatus != 200 {
                    return (HTTPURLResponse(url: url, statusCode: weeklyStatus, httpVersion: nil, headerFields: nil)!, Data())
                }
                if empty {
                    return (ok, Data("{\"totalUsageEventsCount\":0}".utf8))
                }
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let json = """
                {"totalUsageEventsCount":1,"usageEventsDisplay":[
                  {"timestamp":"\(timestamp)","requestsCosts":2,
                   "kind":"USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION","chargedCents":8}]}
                """
                return (ok, Data(json.utf8))
            default:
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
    }

    func testFirstFailureIsUnavailableInsteadOfNoActivity() async {
        let vm = makeViewModel()
        XCTAssertEqual(vm.weeklyChartStatus, .hidden)
        MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 500)

        await vm.refresh()

        XCTAssertEqual(vm.weeklyChartStatus, .unavailable)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)
        XCTAssertNil(vm.weeklyLastUpdated)
        XCTAssertNil(vm.weeklyData)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertNotNil(vm.usageData)
    }

    func testSuccessfulEmptyResponseIsCurrentZeroActivity() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(empty: true)

        await vm.refresh()

        XCTAssertEqual(vm.weeklyChartStatus, .ready)
        XCTAssertNotNil(vm.weeklyLastUpdated)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
        XCTAssertEqual(vm.weeklyData?.count, 7)
        XCTAssertTrue(vm.weeklyData?.allSatisfy { $0.requests == 0 } ?? false)
    }

    func testSummarySuccessDoesNotClearRepeatedWeeklyFailureAndRecoveryResetsIt() async throws {
        for membership in ["ultra", "enterprise"] {
            let vm = makeViewModel()
            MockURLProtocol.requestHandler = Self.handler(membership: membership)
            await vm.refresh()
            let lastSuccess = try XCTUnwrap(vm.weeklyLastUpdated)
            let cachedData = vm.weeklyData
            MockURLProtocol.requestHandler = Self.handler(membership: membership, weeklyStatus: 500)

            await vm.refresh()
            XCTAssertEqual(vm.weeklyChartStatus, .ready)
            XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)
            XCTAssertEqual(vm.weeklyLastUpdated, lastSuccess)

            await vm.refresh()
            XCTAssertEqual(vm.weeklyChartStatus, .stale)
            XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 2)
            XCTAssertEqual(vm.weeklyLastUpdated, lastSuccess)
            XCTAssertEqual(vm.weeklyData, cachedData)
            XCTAssertEqual(vm.consecutiveFailureCount, 0)

            MockURLProtocol.requestHandler = Self.handler(membership: membership, empty: true)
            await vm.refresh()
            XCTAssertEqual(vm.weeklyChartStatus, .ready)
            XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(vm.weeklyLastUpdated), lastSuccess)
        }
    }

    func testShapeRejectionIsUnavailableAndCountsOneFailurePerRefresh() async throws {
        for membership in ["ultra", "enterprise"] {
            for status in [400, 403, 404] {
                let vm = makeViewModel()
                MockURLProtocol.requestHandler = Self.handler(membership: membership)
                await vm.refresh()
                let lastSuccess = try XCTUnwrap(vm.weeklyLastUpdated)
                MockURLProtocol.requestHandler = Self.handler(membership: membership, weeklyStatus: status)

                await vm.refresh()

                XCTAssertEqual(vm.weeklyChartStatus, .unavailable)
                XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)
                XCTAssertEqual(vm.weeklyLastUpdated, lastSuccess)
                XCTAssertNil(vm.weeklyData)
                XCTAssertNil(vm.cachedWeeklyMode)
                XCTAssertFalse(vm.weeklyChartAvailable)
            }
        }
    }

    func testDisabledChartHidesFailureWithoutLosingRefreshState() async {
        let vm = makeViewModel()
        vm.weeklyChartEnabled = false
        MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 500)
        await vm.refresh()
        XCTAssertEqual(vm.weeklyChartStatus, .hidden)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)

        vm.weeklyChartEnabled = true
        XCTAssertEqual(vm.weeklyChartStatus, .unavailable)
    }

    func testAccountSwitchClearsPreviousTimestampAndFailureCount() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler()
        await vm.refresh()
        MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 500)
        await vm.refresh()
        await vm.refresh()
        XCTAssertEqual(vm.weeklyChartStatus, .stale)

        MockURLProtocol.requestHandler = Self.handler(email: "other@example.com", weeklyStatus: 500)
        await vm.refresh()

        XCTAssertNil(vm.weeklyLastUpdated)
        XCTAssertNil(vm.weeklyData)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)
        XCTAssertEqual(vm.weeklyChartStatus, .unavailable)
    }

    func testLogoutClearsWeeklyState() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler()
        await vm.refresh()
        MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 500)
        await vm.refresh()
        let suppression = UserDefaults.standard.object(forKey: "ideAuthSuppressed")
        defer { UserDefaults.standard.set(suppression, forKey: "ideAuthSuppressed") }

        vm.logout()

        XCTAssertNil(vm.weeklyData)
        XCTAssertNil(vm.weeklyLastUpdated)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
        XCTAssertEqual(vm.weeklyChartStatus, .hidden)
    }

    func testSessionExpiryClearsWeeklyState() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler()
        await vm.refresh()
        MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 500)
        await vm.refresh()

        MockURLProtocol.requestHandler = Self.handler(summaryStatus: 401)
        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertNil(vm.weeklyData)
        XCTAssertNil(vm.weeklyLastUpdated)
        XCTAssertNil(vm.cachedWeeklyMode)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
        XCTAssertEqual(vm.weeklyChartStatus, .hidden)
    }

    func testUnknownMembershipDoesNotCountAsWeeklyRequestFailure() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(summaryStatus: 500)

        await vm.refresh()

        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
        XCTAssertNil(vm.weeklyLastUpdated)
        XCTAssertEqual(vm.weeklyChartStatus, .hidden)
    }

    func testIDEOnlySessionExpiryClearsWeeklyState() async {
        let suppression = UserDefaults.standard.object(forKey: "ideAuthSuppressed")
        UserDefaults.standard.removeObject(forKey: "ideAuthSuppressed")
        defer { UserDefaults.standard.set(suppression, forKey: "ideAuthSuppressed") }

        for credentialsMissing in [false, true] {
            let vm = makeViewModel(withCapturedCookie: false)
            let credential = IDECredential(
                cookieHeader: "WorkosCursorSessionToken=ide-test",
                expiresAt: Date().addingTimeInterval(3600)
            )
            vm.ideCredentialProvider = { credential }
            MockURLProtocol.requestHandler = Self.handler()
            await vm.refresh()
            XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
            XCTAssertNotNil(vm.weeklyLastUpdated)
            MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 500)
            await vm.refresh()
            XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)

            if credentialsMissing {
                vm.ideCredentialProvider = { nil }
            } else {
                MockURLProtocol.requestHandler = Self.handler(summaryStatus: 401)
            }
            await vm.refresh()

            XCTAssertEqual(vm.authState, .loginRequired)
            XCTAssertNil(vm.weeklyData)
            XCTAssertNil(vm.weeklyLastUpdated)
            XCTAssertNil(vm.cachedWeeklyMode)
            XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
            XCTAssertEqual(vm.weeklyChartStatus, .hidden)
        }
    }
}
