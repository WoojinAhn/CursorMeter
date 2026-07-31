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
    static func bodyData(from request: URLRequest) -> Data {
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
}

/// #110: a cached weekly fetch shape must not survive a plan change or a
/// wrong-shape rejection. Only 403 cleared it before, so a persistent 400/404
/// (or an enterprise↔personal flip) left a stale chart pinned forever.
@MainActor
final class WeeklyModeInvalidationTests: XCTestCase {

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

    final class PathLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        func record(_ p: String) { lock.lock(); _paths.append(p); lock.unlock() }
        func reset() { lock.lock(); _paths.removeAll(); lock.unlock() }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    }

    /// One handler covering both plan shapes; `membership` drives usage-summary
    /// and `weeklyStatus` the events endpoint, so a single test can flip an
    /// account's plan between refreshes.
    private static func handler(
        log: PathLog,
        membership: String,
        weeklyStatus: Int = 200
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let url = request.url!
            log.record(url.path)
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage-summary":
                let json = """
                {"billingCycleStart":"2026-07-15T03:23:58.561Z","billingCycleEnd":"2026-08-15T03:23:58.561Z",
                 "membershipType":"\(membership)","limitType":"user","isUnlimited":false,
                 "individualUsage":{"plan":{"enabled":true,"used":10,"limit":2000,"remaining":1990,"totalPercentUsed":0.5}}}
                """
                return (ok, Data(json.utf8))
            case "/api/auth/me":
                return (ok, Data("{\"email\":\"u@t.com\",\"name\":\"U\"}".utf8))
            case "/api/usage":
                return (ok, Data("{\"startOfMonth\":\"2026-07-15T03:23:58.561Z\"}".utf8))
            case "/api/dashboard/teams":
                return (ok, Data("{\"teams\":[{\"id\":77,\"name\":\"T\"}]}".utf8))
            case "/api/dashboard/get-team-spend":
                return (ok, Data("{\"teamMemberSpend\":[{\"userId\":42,\"email\":\"u@t.com\",\"hardLimitOverrideDollars\":null}]}".utf8))
            case "/api/dashboard/get-filtered-usage-events":
                guard weeklyStatus == 200 else {
                    return (HTTPURLResponse(url: url, statusCode: weeklyStatus, httpVersion: nil, headerFields: nil)!, Data())
                }
                let nowMs = Int(Date().timeIntervalSince1970 * 1000)
                let json = """
                {"totalUsageEventsCount":1,"usageEventsDisplay":[
                  {"timestamp":"\(nowMs)","requestsCosts":2,
                   "kind":"USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS","chargedCents":8}]}
                """
                return (ok, Data(json.utf8))
            default:
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
        }
    }

    // MARK: - Pure contradiction check

    func test_modeContradiction_matrix() {
        let ent = UsageViewModel.WeeklyMode.enterprise(teamId: 1, userId: 2)
        XCTAssertFalse(UsageViewModel.weeklyModeContradicts(nil, membershipType: "free"))
        XCTAssertFalse(UsageViewModel.weeklyModeContradicts(.personal, membershipType: nil),
                       "nil membership = summary failed; says nothing about the plan (#103)")
        XCTAssertFalse(UsageViewModel.weeklyModeContradicts(.personal, membershipType: "free"))
        XCTAssertFalse(UsageViewModel.weeklyModeContradicts(ent, membershipType: "Enterprise"))
        XCTAssertTrue(UsageViewModel.weeklyModeContradicts(.personal, membershipType: "enterprise"))
        XCTAssertTrue(UsageViewModel.weeklyModeContradicts(ent, membershipType: "pro"))
    }

    // MARK: - Plan change invalidates the cached shape

    func test_planUpgrade_discardsPersonalModeAndRediscovers() async {
        let vm = makeViewModel()
        let log = PathLog()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free")
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)

        // Account becomes enterprise; the cached personal shape must not be used.
        log.reset()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "enterprise")
        await vm.refresh()

        XCTAssertTrue(log.paths.contains("/api/dashboard/teams"),
                      "must re-discover the enterprise shape instead of reusing the personal cache")
        XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 77, userId: 42))
        XCTAssertTrue(vm.weeklyChartAvailable)
    }

    func test_planDowngrade_discardsEnterpriseMode() async {
        let vm = makeViewModel()
        let log = PathLog()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "enterprise")
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 77, userId: 42))

        log.reset()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free")
        await vm.refresh()

        XCTAssertEqual(vm.cachedWeeklyMode, .personal)
        XCTAssertFalse(log.paths.contains("/api/dashboard/get-team-spend"),
                       "personal path must skip roster discovery")
    }

    // MARK: - Wrong-shape rejections (400/404)

    func test_weekly400_clearsModeSoNextRefreshRediscovers() async {
        let vm = makeViewModel()
        let log = PathLog()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "enterprise")
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 77, userId: 42))

        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "enterprise", weeklyStatus: 400)
        await vm.refresh()

        XCTAssertNil(vm.cachedWeeklyMode, "400 = wrong request shape; the cached ids must go")
    }

    func test_weekly404_clearsMode() async {
        let vm = makeViewModel()
        let log = PathLog()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free")
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)

        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free", weeklyStatus: 404)
        await vm.refresh()

        XCTAssertNil(vm.cachedWeeklyMode)
    }

    /// A rejected request shape is not a blip: the chart must come down rather
    /// than pin data that can no longer be refreshed (Codex review P1).
    func test_persistent400_hidesStaleChart() async {
        let vm = makeViewModel()
        let log = PathLog()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free")
        await vm.refresh()
        XCTAssertEqual(vm.weeklyData?.count, 7)

        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free", weeklyStatus: 400)
        await vm.refresh()

        XCTAssertNil(vm.cachedWeeklyMode)
        XCTAssertNil(vm.weeklyData, "stale chart must not survive a rejected shape")
        XCTAssertFalse(vm.weeklyChartAvailable)
    }

    /// Personal is a fixed teamId-0 shape — a rejection must not trigger an
    /// identical retry inside the same refresh (Codex review P2).
    func test_personal400_doesNotRetryInSameRefresh() async {
        let vm = makeViewModel()
        let log = PathLog()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free")
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)

        log.reset()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free", weeklyStatus: 400)
        await vm.refresh()

        let weeklyCalls = log.paths.filter { $0 == "/api/dashboard/get-filtered-usage-events" }.count
        XCTAssertEqual(weeklyCalls, 1, "one rejected call, no same-refresh repeat")
    }

    /// Enterprise DOES have ids worth re-discovering: a rejected cached shape
    /// should recover within the same refresh when discovery succeeds.
    func test_enterprise400_rediscoversAndRecoversInSameRefresh() async {
        let vm = makeViewModel()
        let log = PathLog()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "enterprise")
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 77, userId: 42))

        // Reject only the first (optimistic) events call of the next refresh;
        // the re-discovered call succeeds.
        let rejectedFirst = RejectFirstEventsCall(inner: Self.handler(log: log, membership: "enterprise"))
        log.reset()
        MockURLProtocol.requestHandler = { try rejectedFirst.handle($0) }
        await vm.refresh()

        XCTAssertTrue(log.paths.contains("/api/dashboard/teams"), "re-discovery ran")
        XCTAssertEqual(vm.weeklyData?.count, 7, "chart recovered in the same refresh")
        XCTAssertTrue(vm.weeklyChartAvailable)
        XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 77, userId: 42))
    }

    /// Serves 400 for the first events call, then delegates to the inner handler.
    final class RejectFirstEventsCall: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = false
        private let inner: (URLRequest) throws -> (HTTPURLResponse, Data)
        init(inner: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) { self.inner = inner }
        func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
            if request.url!.path == "/api/dashboard/get-filtered-usage-events" {
                var first = false
                lock.lock(); if !seen { seen = true; first = true }; lock.unlock()
                if first {
                    return (HTTPURLResponse(url: request.url!, statusCode: 400,
                                            httpVersion: nil, headerFields: nil)!, Data())
                }
            }
            return try inner(request)
        }
    }

    /// The counterpart: a transient server error must NOT throw away a working
    /// cache — that was the flaw in the original clear-after-N-failures sketch.
    func test_weekly500_keepsModeAndChart() async {
        let vm = makeViewModel()
        let log = PathLog()
        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free")
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)
        XCTAssertEqual(vm.weeklyData?.count, 7)

        MockURLProtocol.requestHandler = Self.handler(log: log, membership: "free", weeklyStatus: 500)
        await vm.refresh()

        XCTAssertEqual(vm.cachedWeeklyMode, .personal, "5xx is transient — keep the shape")
        XCTAssertEqual(vm.weeklyData?.count, 7, "stale chart retained")
        XCTAssertTrue(vm.weeklyChartAvailable)
    }
}
