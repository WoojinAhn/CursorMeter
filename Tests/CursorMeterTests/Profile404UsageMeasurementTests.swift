import XCTest
@testable import CursorMeter

final class Profile404UsageMeasurementTests: XCTestCase {
    private func summary(_ json: String) throws -> UsageSummaryResponse {
        try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(json.utf8))
    }

    private func usage(_ json: String = "{}") throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    func testUsableMeasurementTable() throws {
        let cases: [(String, Profile404UsageMeasurement?)] = [
            (#"{}"#, nil),
            (#"{"membershipType":"ultra","limitType":"user","isUnlimited":true}"#, nil),
            (#"{"individualUsage":{}}"#, nil),
            (#"{"individualUsage":{"onDemand":{"used":100,"limit":1000}}}"#, nil),
            (#"{"individualUsage":{"plan":{"limit":2000}}}"#, nil),
            (#"{"individualUsage":{"plan":{"limit":2000,"totalPercentUsed":25}}}"#, nil),
            (#"{"individualUsage":{"plan":{"used":-1,"limit":2000}}}"#, nil),
            (#"{"individualUsage":{"plan":{"used":0,"limit":2000}}}"#, .credit(used: 0, limit: 2000)),
            (#"{"individualUsage":{"plan":{"used":500,"limit":2000}}}"#, .credit(used: 500, limit: 2000)),
            (#"{"individualUsage":{"overall":{"used":500,"limit":2000}}}"#, .credit(used: 500, limit: 2000)),
            (#"{"individualUsage":{"plan":{"used":20},"overall":{"used":500,"limit":2000}}}"#, .credit(used: 20, limit: 2000)),
            (#"{"individualUsage":{"plan":{"used":0,"limit":0}}}"#, nil),
            (#"{"individualUsage":{"plan":{"limit":0,"totalPercentUsed":0}}}"#, .percent(0)),
            (#"{"individualUsage":{"plan":{"totalPercentUsed":23.5}}}"#, .percent(23.5)),
            (#"{"individualUsage":{"plan":{"totalPercentUsed":-1}}}"#, nil),
            (#"{"autoModelSelectedDisplayMessage":"You've used 0% of your included usage"}"#, .percent(0)),
            (#"{"autoModelSelectedDisplayMessage":"25% used","individualUsage":{"plan":{"totalPercentUsed":-1}}}"#, .percent(25))
        ]
        for (json, expected) in cases {
            XCTAssertEqual(try summary(json).profile404Measurement(usage: usage(), enterpriseScope: false),
                           expected, json)
        }
    }

    func testSplitPercentagesWithoutDollarsRequireActualEligibleScope() throws {
        let value = try summary(#"{"membershipType":"ultra","individualUsage":{"plan":{"limit":40000,"autoPercentUsed":0,"apiPercentUsed":20}}}"#)
        XCTAssertEqual(value.profile404Measurement(usage: try usage(), enterpriseScope: false), .split)
        XCTAssertNil(value.profile404Measurement(usage: nil, enterpriseScope: false), "Checking alone is not usable")
        XCTAssertNil(value.profile404Measurement(usage: try usage(), enterpriseScope: true))
        XCTAssertNil(value.profile404Measurement(usage: try usage(#"{"legacy":{"numRequests":20,"maxRequestUsage":500}}"#), enterpriseScope: false))
    }

    func testNonFiniteTotalUsesOnlyAValidMessageFallback() {
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            for message in [String?.none, "18% used"] {
                let value = UsageSummaryResponse(billingCycleStart: nil, billingCycleEnd: nil,
                    membershipType: nil, limitType: nil, isUnlimited: nil,
                    autoModelSelectedDisplayMessage: message,
                    individualUsage: IndividualUsage(plan: PlanUsage(enabled: nil, used: nil,
                        limit: nil, remaining: nil, totalPercentUsed: invalid), onDemand: nil, overall: nil),
                    teamUsage: nil)
                XCTAssertEqual(value.profile404Measurement(usage: nil, enterpriseScope: false),
                    message == nil ? nil : .percent(18))
            }
        }
    }

    func testNonFiniteMessagePercentageDoesNotQualify() throws {
        let value = try summary("{\"autoModelSelectedDisplayMessage\":\"\(String(repeating: "9", count: 400))% used\"}")
        XCTAssertNil(value.profile404Measurement(usage: nil, enterpriseScope: false))
    }

    func testPercentMeasurementCannotBecomeFabricatedCreditOrRequests() throws {
        let value = try summary(#"{"membershipType":"enterprise","autoModelSelectedDisplayMessage":"25% used","individualUsage":{"overall":{},"plan":{"totalPercentUsed":-1}}}"#)
        let legacy = try usage(#"{"legacy":{"maxRequestUsage":500}}"#)
        let measurement = try XCTUnwrap(value.profile404Measurement(usage: legacy, enterpriseScope: true))
        let data = UsageDisplayData.from(summary: value, usage: legacy,
            userInfo: .init(email: nil, name: nil), perUserMonthlyLimitDollars: 100,
            perUserOnDemandLimitDollars: 50, profile404Measurement: measurement)
        XCTAssertTrue(data.isPercentOnly)
        XCTAssertFalse(data.isCreditBased)
        XCTAssertEqual(data.percentUsed, 25)
        XCTAssertNil(data.planUsedCents)
        XCTAssertNil(data.planLimitCents)
        XCTAssertEqual(data.requestsLimit, 0)
    }

    func testTokenPercentDoesNotFabricatePaidZero() throws {
        let value = try summary(#"{"autoModelSelectedDisplayMessage":"25% used","individualUsage":{"overall":{}}}"#)
        let data = UsageDisplayData.from(summary: value, usage: nil, userInfo: .init(email: nil, name: nil),
            perUserMonthlyLimitDollars: 100, perUserOnDemandLimitDollars: 50,
            profile404Measurement: .percent(25))
        XCTAssertNil(data.onDemandUsedCents)
        XCTAssertNil(data.onDemandEnabled)
        XCTAssertEqual(data.percentUsed, 25)
    }

    func testCreditMeasurementOverridesLegacyOnlyOnMitigationPath() throws {
        let value = try summary(#"{"individualUsage":{"plan":{"used":500,"limit":2000}}}"#)
        let legacy = try usage(#"{"legacy":{"numRequests":50,"maxRequestUsage":500}}"#)
        let profile = UserInfoResponse(email: nil, name: nil)
        let mitigated = UsageDisplayData.from(summary: value, usage: legacy, userInfo: profile,
            profile404Measurement: .credit(used: 500, limit: 2000))
        XCTAssertEqual(mitigated.planUsedCents, 500)
        XCTAssertEqual(mitigated.percentUsed, 25)
        let healthy = UsageDisplayData.from(summary: value, usage: legacy, userInfo: profile)
        XCTAssertEqual(healthy.requestsLimit, 500)
        XCTAssertNil(healthy.planUsedCents)
    }
}
