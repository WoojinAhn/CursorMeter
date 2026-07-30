import XCTest
@testable import CursorMeter

/// #53 M-2: the date-handling helpers used to lean on `nonisolated(unsafe)`
/// statics (a shared ISO8601DateFormatter and a mutable formatter cache).
/// These tests pin the two properties that made removing them safe: local-day
/// bucketing stays correct under non-UTC calendars, and concurrent off-MainActor
/// use produces correct results.
final class ConcurrentDateHandlingTests: XCTestCase {

    private func calendar(_ tz: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal
    }

    private func event(epochMillis: Int, cost: Double) -> UsageEvent {
        UsageEvent(
            timestamp: String(epochMillis),
            requestsCosts: cost,
            kind: "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS"
        )
    }

    // MARK: - Local-day bucketing (the behavior the day-key formatter provided)

    /// 2026-07-15T20:00Z is 2026-07-16 05:00 in KST — the event must land in the
    /// KST day, not the UTC day. This is what the `yyyy-MM-dd` key encoded and
    /// what `startOfDay` keying must preserve.
    func test_bucketing_usesLocalCalendarDay_notUTC() {
        let kst = calendar("Asia/Seoul")
        let eventUTCEvening = 1784145600000  // 2026-07-15T20:00:00Z = 07-16 05:00 KST
        let todayKST = kst.date(from: DateComponents(
            timeZone: kst.timeZone, year: 2026, month: 7, day: 16, hour: 12))!

        let days = [event(epochMillis: eventUTCEvening, cost: 7)]
            .sevenDayRolling(today: todayKST, calendar: kst)

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last?.requests, 7, "event belongs to today in KST")
        XCTAssertTrue(days.dropLast().allSatisfy { $0.requests == 0 })
    }

    /// Two events 30 minutes apart across local midnight must land in different
    /// buckets — the tightest constraint on whatever the key is.
    func test_bucketing_splitsAcrossLocalMidnight() {
        let kst = calendar("Asia/Seoul")
        // 2026-07-15 23:45 KST and 2026-07-16 00:15 KST
        let before = kst.date(from: DateComponents(
            timeZone: kst.timeZone, year: 2026, month: 7, day: 15, hour: 23, minute: 45))!
        let after = kst.date(from: DateComponents(
            timeZone: kst.timeZone, year: 2026, month: 7, day: 16, hour: 0, minute: 15))!
        let today = kst.date(from: DateComponents(
            timeZone: kst.timeZone, year: 2026, month: 7, day: 16, hour: 12))!

        let days = [
            event(epochMillis: Int(before.timeIntervalSince1970 * 1000), cost: 3),
            event(epochMillis: Int(after.timeIntervalSince1970 * 1000), cost: 5),
        ].sevenDayRolling(today: today, calendar: kst)

        XCTAssertEqual(days[5].requests, 3, "23:45 event → previous local day")
        XCTAssertEqual(days[6].requests, 5, "00:15 event → today")
    }

    // MARK: - Off-MainActor concurrent use

    /// Stress: many concurrent nonisolated calls with *different* time zones —
    /// the shape that made the shared formatter cache a race. Correctness of
    /// every result is asserted, so a corrupted shared formatter surfaces as a
    /// wrong day bucket rather than only as a crash.
    func test_sevenDayRolling_concurrentAcrossTimeZones() async {
        let zones = ["Asia/Seoul", "UTC", "America/New_York", "Europe/Berlin", "Australia/Sydney"]

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<200 {
                let cal = calendar(zones[i % zones.count])
                group.addTask {
                    let today = cal.date(from: DateComponents(
                        timeZone: cal.timeZone, year: 2026, month: 7, day: 16, hour: 12))!
                    let eventDate = cal.date(byAdding: .day, value: -2, to: today)!
                    let days = [UsageEvent(
                        timestamp: String(Int(eventDate.timeIntervalSince1970 * 1000)),
                        requestsCosts: 11,
                        kind: "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS"
                    )].sevenDayRolling(today: today, calendar: cal)
                    return days.count == 7 && days[4].requests == 11
                        && days.enumerated().allSatisfy { $0.offset == 4 || $0.element.requests == 0 }
                }
            }
            for await ok in group {
                XCTAssertTrue(ok, "concurrent rolling fold produced a wrong bucket")
            }
        }
    }

    /// Same shape for the ISO8601 parse path (`UsageDisplayData.from` → parseDate).
    func test_dateParsing_concurrentFactoryCalls() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    let summary = UsageSummaryResponse(
                        billingCycleStart: "2026-07-15T03:23:58.561Z",
                        billingCycleEnd: "2026-08-15T03:23:58.561Z",
                        membershipType: "free",
                        limitType: "user",
                        isUnlimited: false,
                        autoModelSelectedDisplayMessage: nil,
                        individualUsage: IndividualUsage(
                            plan: PlanUsage(enabled: true, used: 0, limit: 0,
                                            remaining: 0, totalPercentUsed: 2.5),
                            onDemand: nil, overall: nil),
                        teamUsage: nil
                    )
                    let data = UsageDisplayData.from(
                        summary: summary, usage: nil,
                        userInfo: UserInfoResponse(email: "a@b.c", name: "A"))
                    // Both dates must parse; a corrupted shared formatter yields nil.
                    return data.cycleStartDate != nil && data.resetDate != nil
                }
            }
            for await ok in group {
                XCTAssertTrue(ok, "concurrent ISO8601 parse returned nil")
            }
        }
    }
}
