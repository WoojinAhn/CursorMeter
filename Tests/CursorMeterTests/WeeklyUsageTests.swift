import XCTest
@testable import CursorMeter

final class WeeklyUsageTests: XCTestCase {

    // MARK: - Helpers

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.calendar = utcCalendar
        f.timeZone = utcCalendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)!
    }

    /// MockURLProtocol receives `URLRequest` with `httpBody` stripped — the
    /// body is delivered via `httpBodyStream` instead. Reads whichever is
    /// available so assertions on body content are resilient.
    private static func bodyData(from request: URLRequest) -> Data {
        if let direct = request.httpBody { return direct }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var out = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            out.append(buffer, count: read)
        }
        return out
    }

    private func event(_ ymd: String, cost: Double, hour: Int = 12) -> UsageEvent {
        var comps = DateComponents()
        let day = utcCalendar.dateComponents([.year, .month, .day], from: date(ymd))
        comps.year = day.year; comps.month = day.month; comps.day = day.day
        comps.hour = hour
        comps.timeZone = utcCalendar.timeZone
        let d = utcCalendar.date(from: comps)!
        let ms = Int(d.timeIntervalSince1970 * 1000)
        return UsageEvent(
            timestamp: String(ms),
            requestsCosts: cost,
            kind: "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS"
        )
    }

    /// Convenience for tests that need an on-demand-billed event on a given day.
    private func onDemandEvent(_ ymd: String, cost: Double, charged: Double, hour: Int = 12) -> UsageEvent {
        var comps = DateComponents()
        let day = utcCalendar.dateComponents([.year, .month, .day], from: date(ymd))
        comps.year = day.year; comps.month = day.month; comps.day = day.day
        comps.hour = hour
        comps.timeZone = utcCalendar.timeZone
        let d = utcCalendar.date(from: comps)!
        let ms = Int(d.timeIntervalSince1970 * 1000)
        return UsageEvent(
            timestamp: String(ms),
            requestsCosts: cost,
            kind: "USAGE_EVENT_KIND_USAGE_BASED",
            chargedCents: charged
        )
    }

    // MARK: - Response parsing

    func testParseEventsResponse() throws {
        let json = """
        {
          "totalUsageEventsCount": 2,
          "usageEventsDisplay": [
            {"timestamp": "1780402687672", "requestsCosts": 2},
            {"timestamp": "1780402643496", "requestsCosts": 30.5}
          ]
        }
        """
        let response = try JSONDecoder().decode(
            FilteredUsageEventsResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.totalUsageEventsCount, 2)
        XCTAssertEqual(response.usageEventsDisplay.count, 2)
        XCTAssertEqual(response.usageEventsDisplay[0].requestsCosts, 2)
        XCTAssertEqual(response.usageEventsDisplay[1].requestsCosts, 30.5)
    }

    func testParseEmptyEventsResponse() throws {
        let json = """
        { "totalUsageEventsCount": 0, "usageEventsDisplay": [] }
        """
        let response = try JSONDecoder().decode(
            FilteredUsageEventsResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertTrue(response.usageEventsDisplay.isEmpty)
    }

    func testParseEventReadsKindAndChargedCents() throws {
        // Real payload has many extra keys (model, tokenUsage, etc.); only the
        // four fields below are needed by the chart logic.
        let json = """
        {
          "timestamp": "1780402687672",
          "requestsCosts": 2,
          "model": "composer-2.5-fast",
          "kind": "USAGE_EVENT_KIND_USAGE_BASED",
          "tokenUsage": {"totalCents": 18.17},
          "chargedCents": 95.69
        }
        """
        let event = try JSONDecoder().decode(UsageEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.kind, "USAGE_EVENT_KIND_USAGE_BASED")
        XCTAssertEqual(event.chargedCents, 95.69)
    }

    func testParseEventStillIgnoresUnusedFields() throws {
        let json = """
        {
          "timestamp": "1780402687672",
          "requestsCosts": 2,
          "model": "composer-2.5-fast",
          "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
          "tokenUsage": {"totalCents": 18.17},
          "chargedCents": 8
        }
        """
        let event = try JSONDecoder().decode(UsageEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.timestamp, "1780402687672")
        XCTAssertEqual(event.requestsCosts, 2)
    }

    // MARK: - UsageEvent helpers

    func testEventDateParsesMillis() {
        let e = UsageEvent(timestamp: "1780402687672", requestsCosts: 1)
        XCTAssertEqual(e.date?.timeIntervalSince1970, 1780402687.672)
    }

    func testEventDateReturnsNilForMalformedTimestamp() {
        let e = UsageEvent(timestamp: "not-a-number", requestsCosts: 1)
        XCTAssertNil(e.date)
    }

    func testRequestsCostsSafeFallsBackOnNil() {
        let e = UsageEvent(timestamp: "1780402687672", requestsCosts: nil)
        XCTAssertEqual(e.requestsCostsSafe, 0)
    }

    func testRequestsCostsSafeFallsBackOnInfinity() {
        let e = UsageEvent(timestamp: "1780402687672", requestsCosts: .infinity)
        XCTAssertEqual(e.requestsCostsSafe, 0)
    }

    func testIsOnDemandBilledTrueForUsageBased() {
        let e = UsageEvent(timestamp: "1", kind: "USAGE_EVENT_KIND_USAGE_BASED")
        XCTAssertTrue(e.isOnDemandBilled)
    }

    func testIsOnDemandBilledFalseForOtherKinds() {
        for kind in [
            "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
            "USAGE_EVENT_KIND_FREE_CREDIT",
            "USAGE_EVENT_KIND_ERRORED_NOT_CHARGED",
            "SOME_FUTURE_KIND",
        ] {
            let e = UsageEvent(timestamp: "1", kind: kind)
            XCTAssertFalse(e.isOnDemandBilled, "kind=\(kind) should not count as on-demand")
        }
    }

    func testIsOnDemandBilledFalseForNilKind() {
        let e = UsageEvent(timestamp: "1", kind: nil)
        XCTAssertFalse(e.isOnDemandBilled)
    }

    func testChargedCentsSafeFallsBackOnNilAndInfinity() {
        XCTAssertEqual(UsageEvent(timestamp: "1", chargedCents: nil).chargedCentsSafe, 0)
        XCTAssertEqual(UsageEvent(timestamp: "1", chargedCents: .infinity).chargedCentsSafe, 0)
        XCTAssertEqual(UsageEvent(timestamp: "1", chargedCents: 95.69).chargedCentsSafe, 95.69)
    }

    // MARK: - sevenDayRolling

    func testSevenDayRollingProducesSevenEntries() {
        let days = ([] as [UsageEvent]).sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days.count, 7)
    }

    func testSevenDayRollingTodayIsRightmost() {
        let days = ([] as [UsageEvent]).sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertTrue(days.last!.isToday)
        XCTAssertFalse(days.dropLast().contains(where: { $0.isToday }))
    }

    func testSevenDayRollingZeroFillsMissingDates() {
        let days = ([] as [UsageEvent]).sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertTrue(days.allSatisfy { $0.requests == 0 })
    }

    func testSevenDayRollingSumsCostsPerDay() {
        let events: [UsageEvent] = [
            event("2026-05-08", cost: 13),
            event("2026-05-08", cost: 2),
            event("2026-05-13", cost: 7),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        // Window: 05-07, 05-08, 05-09, 05-10, 05-11, 05-12, 05-13
        XCTAssertEqual(days[0].requests, 0, "2026-05-07 missing")
        XCTAssertEqual(days[1].requests, 15, "2026-05-08: 13 + 2")
        XCTAssertEqual(days[6].requests, 7, "today (2026-05-13)")
    }

    func testSevenDayRollingIgnoresEventsOutsideWindow() {
        let events: [UsageEvent] = [
            event("2026-05-01", cost: 999),
            event("2026-05-20", cost: 999),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days.map(\.requests), [0, 0, 0, 0, 0, 0, 0])
    }

    func testSevenDayRollingRoundsFractionalCosts() {
        let events: [UsageEvent] = [
            event("2026-05-13", cost: 2.7),
            event("2026-05-13", cost: 3.5),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days[6].requests, 6, "2.7 + 3.5 = 6.2 → rounds to 6")
    }

    func testSevenDayRollingSkipsMalformedTimestamps() {
        let events: [UsageEvent] = [
            UsageEvent(timestamp: "nope", requestsCosts: 999),
            event("2026-05-13", cost: 5),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days[6].requests, 5)
    }

    func testSevenDayRollingTreatsNilCostAsZero() {
        let events: [UsageEvent] = [
            UsageEvent(timestamp: String(Int(date("2026-05-13").timeIntervalSince1970 * 1000)), requestsCosts: nil),
            event("2026-05-13", cost: 4),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days[6].requests, 4)
    }

    // MARK: - sevenDayRolling — mode detection (#68)

    func testPlanOnlyDayMarksIsOnDemandFalse() {
        let events: [UsageEvent] = [event("2026-05-13", cost: 10)]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertFalse(days[6].isOnDemand)
        XCTAssertEqual(days[6].onDemandCents, 0)
    }

    func testOnDemandDayMarksIsOnDemandTrueAndSumsCents() {
        let events: [UsageEvent] = [
            onDemandEvent("2026-05-13", cost: 23.9, charged: 95.69),
            onDemandEvent("2026-05-13", cost: 10.0, charged: 40.0),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertTrue(days[6].isOnDemand)
        XCTAssertEqual(days[6].onDemandCents, 136, "95.69 + 40.0 = 135.69 → rounds to 136")
    }

    func testMixedDayUsesAllRequestsCostsForHeightButOnlyUsageBasedForCents() {
        let events: [UsageEvent] = [
            event("2026-05-13", cost: 100),                            // plan, no charge
            onDemandEvent("2026-05-13", cost: 50, charged: 200),       // on-demand $2.00
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days[6].requests, 150, "height counts both: 100 + 50")
        XCTAssertTrue(days[6].isOnDemand, "any USAGE_BASED → on-demand day")
        XCTAssertEqual(days[6].onDemandCents, 200, "only USAGE_BASED contributes to cents")
    }

    func testMixedWindowSomeDaysOnDemandOthersPlan() {
        let events: [UsageEvent] = [
            event("2026-05-13", cost: 5),                              // today: plan
            onDemandEvent("2026-05-08", cost: 20, charged: 80),        // 5 days ago: on-demand
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        // Window: 05-07, 05-08, 05-09, 05-10, 05-11, 05-12, 05-13
        XCTAssertTrue(days[1].isOnDemand, "2026-05-08 should be on-demand")
        XCTAssertEqual(days[1].onDemandCents, 80)
        XCTAssertFalse(days[6].isOnDemand, "today should be plan")
        XCTAssertEqual(days[6].onDemandCents, 0)
    }

    func testFreeCreditAndErroredDoNotTriggerOnDemand() {
        let events: [UsageEvent] = [
            UsageEvent(timestamp: String(Int(date("2026-05-13").timeIntervalSince1970 * 1000) + 1000),
                       requestsCosts: 10, kind: "USAGE_EVENT_KIND_FREE_CREDIT", chargedCents: 50),
            UsageEvent(timestamp: String(Int(date("2026-05-13").timeIntervalSince1970 * 1000) + 2000),
                       requestsCosts: 5, kind: "USAGE_EVENT_KIND_ERRORED_NOT_CHARGED", chargedCents: 0),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertFalse(days[6].isOnDemand)
        XCTAssertEqual(days[6].onDemandCents, 0)
        XCTAssertEqual(days[6].requests, 15, "both still contribute to height regardless of kind")
    }

    // MARK: - tooltipText (WeeklyUsageChartView)

    private func day(
        requests: Int = 0,
        isOnDemand: Bool = false,
        onDemandCents: Int = 0,
        totalChargedCents: Int = 0
    ) -> DayUsage {
        DayUsage(
            date: Date(timeIntervalSince1970: 0),
            requests: requests,
            isToday: false,
            isOnDemand: isOnDemand,
            onDemandCents: onDemandCents,
            totalChargedCents: totalChargedCents
        )
    }

    func testTooltipTextPlanDayRequestQuotaShowsInteger() {
        let d = day(requests: 929, totalChargedCents: 1234)
        // Request-quota plan: integer wins, totalChargedCents ignored.
        XCTAssertEqual(WeeklyUsageChartView.tooltipText(for: d, creditBased: false), "929")
    }

    func testTooltipTextOnDemandDayShowsDollarsRegardlessOfPlanType() {
        let d = day(requests: 50, isOnDemand: true, onDemandCents: 96, totalChargedCents: 200)
        XCTAssertEqual(WeeklyUsageChartView.tooltipText(for: d, creditBased: false), "$0.96")
        XCTAssertEqual(WeeklyUsageChartView.tooltipText(for: d, creditBased: true), "$0.96")
    }

    func testTooltipTextOnDemandDayRoundsCentsToTwoDecimals() {
        let d = day(requests: 10, isOnDemand: true, onDemandCents: 4000)
        XCTAssertEqual(WeeklyUsageChartView.tooltipText(for: d, creditBased: false), "$40.00")
    }

    // #72 — token-based enterprise plan: plan-day tooltip switches to dollars
    // (matches the popover's `$used / $limit` denominator).

    func testTooltipTextPlanDayTokenBasedShowsDollars() {
        let d = day(requests: 929, totalChargedCents: 520)
        XCTAssertEqual(WeeklyUsageChartView.tooltipText(for: d, creditBased: true), "$5.20")
    }

    func testTooltipTextPlanDayTokenBasedZeroCents() {
        let d = day(requests: 0, totalChargedCents: 0)
        XCTAssertEqual(WeeklyUsageChartView.tooltipText(for: d, creditBased: true), "$0.00")
    }

    // MARK: - sevenDayRolling — totalChargedCents accumulates across all kinds (#72)

    func testSevenDayRollingTotalChargedCentsSumsAllKinds() {
        let included = event("2026-05-13", cost: 10)                              // plan: chargedCents nil → 0
        let onDemand = onDemandEvent("2026-05-13", cost: 5, charged: 250)         // 250
        let freeCredit = UsageEvent(
            timestamp: String(Int(date("2026-05-13").timeIntervalSince1970 * 1000) + 1000),
            requestsCosts: 3,
            kind: "USAGE_EVENT_KIND_FREE_CREDIT",
            chargedCents: 80
        )
        let days = [included, onDemand, freeCredit].sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days[6].totalChargedCents, 330, "0 + 250 + 80 = 330 across all kinds")
        XCTAssertEqual(days[6].onDemandCents, 250, "only USAGE_BASED contributes to onDemandCents")
    }

    func testSevenDayRollingTotalChargedCentsZeroOnEmptyDay() {
        let days = ([] as [UsageEvent]).sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertTrue(days.allSatisfy { $0.totalChargedCents == 0 })
    }

    // MARK: - oldestEventDate

    func testOldestEventDateOnEmpty() {
        XCTAssertNil(([] as [UsageEvent]).oldestEventDate())
    }

    func testOldestEventDatePicksMin() {
        let events: [UsageEvent] = [
            event("2026-05-13", cost: 1),
            event("2026-05-08", cost: 1),
            event("2026-05-10", cost: 1),
        ]
        let oldest = events.oldestEventDate()
        XCTAssertEqual(oldest?.timeIntervalSince1970, event("2026-05-08", cost: 1).date?.timeIntervalSince1970)
    }

    // MARK: - collectWeeklyEvents pagination

    func testCollectWeeklyEventsStopsOnOldEvent() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var pagesRequested: [Int] = []
        MockURLProtocol.requestHandler = { request in
            let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: Any]) ?? [:]
            let page = body["page"] as? Int ?? 0
            pagesRequested.append(page)
            // Page 1: events from yesterday + 8 days ago — second event triggers stop.
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let oldMs = Int(self.date("2026-05-05").timeIntervalSince1970 * 1000)
            let newMs = Int(self.date("2026-05-12").timeIntervalSince1970 * 1000)
            let json = """
            { "totalUsageEventsCount": 2,
              "usageEventsDisplay": [
                {"timestamp": "\(newMs)", "requestsCosts": 1},
                {"timestamp": "\(oldMs)", "requestsCosts": 1}
              ] }
            """
            return (resp, Data(json.utf8))
        }

        let events = try await UsageViewModel.collectWeeklyEvents(
            apiClient: client,
            cookieHeader: "session=x",
            teamId: 42,
            userId: 232352588,
            pageSize: 100,
            maxPages: 5,
            today: date("2026-05-13"),
            calendar: utcCalendar
        )

        XCTAssertEqual(pagesRequested, [1], "stopped after page 1 because oldest event < cutoff")
        XCTAssertEqual(events.count, 2)
    }

    func testCollectWeeklyEventsHitsMaxPagesCap() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var pagesRequested: [Int] = []
        MockURLProtocol.requestHandler = { request in
            let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: Any]) ?? [:]
            let page = body["page"] as? Int ?? 0
            pagesRequested.append(page)
            // Every page returns events within the 7-day window — paginator never stops naturally.
            let newMs = Int(self.date("2026-05-13").timeIntervalSince1970 * 1000)
            let json = """
            { "totalUsageEventsCount": 600,
              "usageEventsDisplay": [
                {"timestamp": "\(newMs)", "requestsCosts": 1}
              ] }
            """
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        _ = try await UsageViewModel.collectWeeklyEvents(
            apiClient: client,
            cookieHeader: "session=x",
            teamId: 42,
            userId: 232352588,
            pageSize: 100,
            maxPages: 5,
            today: date("2026-05-13"),
            calendar: utcCalendar
        )

        XCTAssertEqual(pagesRequested, [1, 2, 3, 4, 5])
    }

    func testCollectWeeklyEventsStopsOnEmptyPage() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var pagesRequested: [Int] = []
        MockURLProtocol.requestHandler = { request in
            let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: Any]) ?? [:]
            let page = body["page"] as? Int ?? 0
            pagesRequested.append(page)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            { "totalUsageEventsCount": 0, "usageEventsDisplay": [] }
            """
            return (resp, Data(json.utf8))
        }

        let events = try await UsageViewModel.collectWeeklyEvents(
            apiClient: client,
            cookieHeader: "session=x",
            teamId: 42,
            userId: 232352588,
            pageSize: 100,
            maxPages: 5,
            today: date("2026-05-13"),
            calendar: utcCalendar
        )

        XCTAssertEqual(pagesRequested, [1])
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - fetchWeeklyUsage (CursorAPIClient request shape)

    func testFetchWeeklyUsageSendsOriginAndBody() async throws {
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
            teamId: 42,
            userId: 232352588,
            page: 3,
            pageSize: 50
        )

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(request.url!.path.hasSuffix("/api/dashboard/get-filtered-usage-events"))

        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: Any])
        XCTAssertEqual(parsed["teamId"] as? Int, 42)
        XCTAssertEqual(parsed["userId"] as? Int, 232352588)
        XCTAssertEqual(parsed["page"] as? Int, 3)
        XCTAssertEqual(parsed["pageSize"] as? Int, 50)
    }

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

    func testFetchWeeklyUsage403ThrowsForbidden() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        do {
            _ = try await client.fetchWeeklyUsage(
                cookieHeader: "session=x",
                teamId: 42,
                userId: 232352588,
                page: 1
            )
            XCTFail("Expected forbidden")
        } catch APIError.forbidden {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - dailyRequestBudget (still used by other call sites — leave covered)

    private func makeDisplayData(
        requestsLimit: Int,
        cycleStart: String?,
        cycleEnd: String?
    ) -> UsageDisplayData {
        UsageDisplayData(
            email: "x", name: "x", membershipType: "enterprise",
            planUsedCents: nil, planLimitCents: nil,
            serverPercentUsed: nil,
            requestsUsed: 0,
            requestsLimit: requestsLimit,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            onDemandEnabled: nil,
            isOnDemandActive: false,
            cycleStartDate: cycleStart.map { date($0) },
            resetDate: cycleEnd.map { date($0) }
        )
    }

    func testDailyRequestBudgetStillReturnsValue() {
        // Property is no longer consumed by the chart but other display logic
        // may still reference it. Keep coverage to catch accidental removal.
        let data = makeDisplayData(
            requestsLimit: 1500,
            cycleStart: "2026-05-01",
            cycleEnd: "2026-06-01"
        )
        XCTAssertEqual(data.dailyRequestBudget, 1500 / 31)
    }

    // MARK: - WeeklyChartStyle + UsageViewModel settings persistence

    @MainActor
    func testWeeklyChartStyleRawValueRoundTrip() {
        for style in WeeklyChartStyle.allCases {
            XCTAssertEqual(WeeklyChartStyle(rawValue: style.rawValue), style)
        }
    }

    @MainActor
    func testWeeklyChartSettingsDefaults() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        XCTAssertTrue(vm.weeklyChartEnabled)
        XCTAssertEqual(vm.weeklyChartStyle, .outline)
    }

    @MainActor
    func testSetWeeklyChartEnabledPersists() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        vm.setWeeklyChartEnabled(false)

        XCTAssertFalse(vm.weeklyChartEnabled)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "weeklyChartEnabled"), false)

        let reloaded = UsageViewModel()
        XCTAssertFalse(reloaded.weeklyChartEnabled)
    }

    @MainActor
    func testSetWeeklyChartStylePersists() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        vm.setWeeklyChartStyle(.both)

        XCTAssertEqual(vm.weeklyChartStyle, .both)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "weeklyChartStyle"), WeeklyChartStyle.both.rawValue)

        let reloaded = UsageViewModel()
        XCTAssertEqual(reloaded.weeklyChartStyle, .both)
    }

    private func clearWeeklyChartDefaults() {
        UserDefaults.standard.removeObject(forKey: "weeklyChartEnabled")
        UserDefaults.standard.removeObject(forKey: "weeklyChartStyle")
    }
}
