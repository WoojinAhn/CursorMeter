import XCTest
@testable import CursorMeter

final class SplitUsageModelsTests: XCTestCase {
    func testOptionalPoolFieldsAreBoundaryTolerant() throws {
        let data = Data(#"{"used":12,"limit":100,"autoPercentUsed":"bad","apiPercentUsed":-1}"#.utf8)
        let plan = try JSONDecoder().decode(PlanUsage.self, from: data)
        XCTAssertEqual(plan.used, 12)
        XCTAssertNil(plan.autoPercentUsed)
        XCTAssertNil(plan.apiPercentUsed)
    }
    func testIndependentPoolAndPaidCopy() throws {
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(#"{"individualUsage":{"plan":{"used":12,"limit":100,"autoPercentUsed":12.3,"apiPercentUsed":103}}}"#.utf8))
        var display = UsageDisplayData.from(summary: summary, usage: UsageResponse(models: [:], startOfMonth: nil), userInfo: UserInfoResponse(email: nil, name: nil))
        display.splitUsage = SplitUsageSnapshot(identity: .init(localID: 1, credentialGeneration: 0, accountDigest: "a", scopeDigest: "s", cycle: nil, planIdentity: "p"), capturedAt: Date(), cursorPercent: 12.3, otherPercent: 103, includedUsedCents: 12)
        XCTAssertEqual(display.withOnDemandActive(true).splitUsage, display.splitUsage)
        XCTAssertEqual(summary.individualUsage?.plan?.apiPercentUsed, 103)
    }
    func testEligibilityRequiresSuccessfulUsageAndPersonalPaidScope() throws {
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(#"{"membershipType":"pro","individualUsage":{"plan":{"used":12,"limit":100,"autoPercentUsed":12.3}}}"#.utf8))
        XCTAssertEqual(SplitUsageEligibility.evaluate(summary: summary, usage: nil), .checking)
        XCTAssertEqual(SplitUsageEligibility.evaluate(summary: summary, usage: UsageResponse(models: [:], startOfMonth: nil)), .eligible)
    }
    func testPeriodDoesNotSubstituteTotalSpend() throws {
        let period = try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data(#"{"planUsage":{"totalSpend":100,"autoPercentUsed":5}}"#.utf8))
        XCTAssertNil(period.planUsage?.includedSpend)
    }
    func testEmptyTeamObjectRemainsPersonalButTeamMembershipDoesNot() throws {
        let usage = UsageResponse(models: [:], startOfMonth: nil)
        for (team, membership, expected) in [("{}", "pro", SplitUsageEligibility.eligible), ("{\"mystery\":1}", "pro", .legacy), ("{}", "teams", .legacy)] {
            let raw = "{\"membershipType\":\"\(membership)\",\"teamUsage\":\(team),\"individualUsage\":{\"plan\":{\"used\":12,\"limit\":100,\"autoPercentUsed\":12}}}"
            let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(raw.utf8))
            XCTAssertEqual(SplitUsageEligibility.evaluate(summary: summary, usage: usage), expected)
        }
    }

}
