import XCTest
@testable import CursorMeter

@MainActor
final class CurrentPeriodUsageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ideAuthSuppressed")
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        UserDefaults.standard.removeObject(forKey: "ideAuthSuppressed")
        super.tearDown()
    }

    private let ultraJSON = """
    {
        "billingCycleStart": "1787312054000",
        "billingCycleEnd": "1789990454000",
        "planUsage": {
            "totalSpend": 138473,
            "includedSpend": 40000,
            "bonusSpend": 98473,
            "limit": 40000,
            "remainingBonus": false,
            "autoPercentUsed": 31.883333333333336,
            "apiPercentUsed": 85.646,
            "totalPercentUsed": 39.56371428571428
        },
        "spendLimitUsage": { "limitType": "user" },
        "enabled": true,
        "autoModelSelectedDisplayMessage": "You've used 40% of your included total usage",
        "namedModelSelectedDisplayMessage": "You've used 86% of your included API usage"
    }
    """

    func testDecodeUltraPayload() throws {
        let decoded = try JSONDecoder().decode(
            CurrentPeriodUsageResponse.self, from: Data(ultraJSON.utf8))
        XCTAssertEqual(decoded.planUsage?.autoPercentUsed ?? 0, 31.8833, accuracy: 0.001)
        XCTAssertEqual(decoded.planUsage?.apiPercentUsed ?? 0, 85.646, accuracy: 0.001)
        XCTAssertEqual(decoded.planUsage?.totalPercentUsed ?? 0, 39.5637, accuracy: 0.001)
    }

    func testDecodeMissingPlanUsage() throws {
        let decoded = try JSONDecoder().decode(
            CurrentPeriodUsageResponse.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.planUsage)
    }

    func testFetchSendsPostWithOriginAndEmptyBody() async throws {
        final class RequestBox: @unchecked Sendable {
            var method: String?
            var origin: String?
            var path: String?
        }
        let box = RequestBox()
        MockURLProtocol.requestHandler = { request in
            box.method = request.httpMethod
            box.origin = request.value(forHTTPHeaderField: "Origin")
            box.path = request.url?.path
            let ok = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (ok, Data(#"{"planUsage":{"autoPercentUsed":1,"apiPercentUsed":2,"totalPercentUsed":1.5}}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)

        let result = try await client.fetchCurrentPeriodUsage(cookieHeader: "session=x")

        XCTAssertEqual(box.method, "POST")
        XCTAssertEqual(box.origin, "https://cursor.com")
        XCTAssertEqual(box.path, "/api/dashboard/get-current-period-usage")
        XCTAssertEqual(result.planUsage?.autoPercentUsed, 1)
        MockURLProtocol.requestHandler = nil
    }

    func testFromSummaryPrefersPeriodPercentsOverPlan() {
        let summary = UsageSummaryResponse(
            billingCycleStart: "2026-08-21T11:34:14.000Z",
            billingCycleEnd: "2026-09-21T11:34:14.000Z",
            membershipType: "ultra",
            limitType: "user",
            isUnlimited: false,
            autoModelSelectedDisplayMessage: nil,
            individualUsage: IndividualUsage(
                plan: PlanUsage(
                    enabled: true, used: 400, limit: 400,
                    remaining: 0, totalPercentUsed: 10,
                    autoPercentUsed: 10, apiPercentUsed: 10),
                onDemand: nil, overall: nil),
            teamUsage: nil
        )
        let period = CurrentPeriodUsageResponse(
            planUsage: CurrentPeriodPlanUsage(
                autoPercentUsed: 31.88, apiPercentUsed: 85.65, totalPercentUsed: 39.56)
        )
        let data = UsageDisplayData.from(
            summary: summary, usage: nil,
            userInfo: UserInfoResponse(email: "t@t.com", name: "T"),
            period: period
        )
        XCTAssertEqual(data.cursorModelsPercent ?? 0, 31.88, accuracy: 0.01)
        XCTAssertEqual(data.otherModelsPercent ?? 0, 85.65, accuracy: 0.01)
        XCTAssertTrue(data.hasBucketMeters)
        XCTAssertEqual(data.percentUsed, 39.56, accuracy: 0.01)
        XCTAssertEqual(data.percentText, "40%")
        XCTAssertEqual(data.usageLabel, "Cursor 32%")
        XCTAssertEqual(data.usageText, "Other 86%")
        XCTAssertEqual(data.menuBarBucketText, "32% · 86%")
        XCTAssertEqual(data.menuBarRingPercent, 85.65, accuracy: 0.01)
    }

    func testFromSummaryFallsBackToPlanBucketPercents() {
        let summary = UsageSummaryResponse(
            billingCycleStart: nil,
            billingCycleEnd: "2026-09-21T11:34:14.000Z",
            membershipType: "ultra",
            limitType: nil,
            isUnlimited: nil,
            autoModelSelectedDisplayMessage: nil,
            individualUsage: IndividualUsage(
                plan: PlanUsage(
                    enabled: true, used: 0, limit: 40000,
                    remaining: 0, totalPercentUsed: 39.56,
                    autoPercentUsed: 31.88, apiPercentUsed: 85.65),
                onDemand: nil, overall: nil),
            teamUsage: nil
        )
        let data = UsageDisplayData.from(
            summary: summary, usage: nil,
            userInfo: UserInfoResponse(email: "t@t.com", name: "T")
        )
        XCTAssertTrue(data.hasBucketMeters)
        XCTAssertEqual(data.percentUsed, 39.56, accuracy: 0.01)
        XCTAssertEqual(data.cursorModelsPercent ?? 0, 31.88, accuracy: 0.01)
    }

    func testCreditPlanWithoutBucketsStillUsesCentsRatio() {
        let data = UsageDisplayData(
            email: "t@t.com", name: "T", membershipType: "pro",
            planUsedCents: 800, planLimitCents: 2000, serverPercentUsed: 3,
            requestsUsed: 0, requestsLimit: 0,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            onDemandEnabled: nil, isOnDemandActive: false,
            cycleStartDate: nil, resetDate: nil
        )
        XCTAssertFalse(data.hasBucketMeters)
        XCTAssertEqual(data.percentUsed, 40.0, accuracy: 0.01)
    }

    func testRefreshAppliesPeriodUsageWhenAuthMe404s() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.updateCheckRunner = { .upToDate }
        vm.ideCredentialProvider = {
            IDECredential(
                cookieHeader: "WorkosCursorSessionToken=ide",
                expiresAt: Date().addingTimeInterval(3600)
            )
        }
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage-summary":
                return (ok, Data("""
                {"billingCycleStart":"2026-08-21T00:00:00.000Z","billingCycleEnd":"2026-09-21T00:00:00.000Z",
                 "membershipType":"ultra","individualUsage":{"plan":{"enabled":true,"used":40000,"limit":40000,
                 "totalPercentUsed":10}}}
                """.utf8))
            case "/api/dashboard/get-current-period-usage":
                return (ok, Data("""
                {"planUsage":{"autoPercentUsed":31.88,"apiPercentUsed":85.65,"totalPercentUsed":39.56}}
                """.utf8))
            case "/api/auth/me":
                let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (notFound, Data("missing".utf8))
            case "/api/usage":
                return (ok, Data("{\"startOfMonth\":\"2026-08-21T00:00:00.000Z\"}".utf8))
            default:
                let err = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (err, Data("{}".utf8))
            }
        }

        await vm.refresh()
        MockURLProtocol.requestHandler = nil

        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertTrue(vm.usageData?.hasBucketMeters == true)
        XCTAssertEqual(vm.usageData?.percentUsed ?? 0, 39.56, accuracy: 0.01)
        XCTAssertEqual(vm.usageData?.cursorModelsPercent ?? 0, 31.88, accuracy: 0.01)
        XCTAssertEqual(vm.usageData?.otherModelsPercent ?? 0, 85.65, accuracy: 0.01)
    }
}
