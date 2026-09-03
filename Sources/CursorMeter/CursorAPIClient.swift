import Foundation

enum APIError: Error {
    case unauthorized
    case forbidden
    case httpError(statusCode: Int)
    case networkError(Error)
}

actor CursorAPIClient {
    private static let usageURL = URL(string: "https://cursor.com/api/usage")!
    private static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let userInfoURL = URL(string: "https://cursor.com/api/auth/me")!
    private static let teamsURL = URL(string: "https://cursor.com/api/dashboard/teams")!
    // All endpoints now use the bare-host canonical URL. Dashboard POST endpoints
    // enforce origin checks with `Origin: https://cursor.com` — the www. redirect
    // would cause a CSRF rejection on state-changing operations.
    private static let filteredUsageEventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    private static let teamSpendURL = URL(string: "https://cursor.com/api/dashboard/get-team-spend")!
    private static let hardLimitURL = URL(string: "https://cursor.com/api/dashboard/get-hard-limit")!
    private static let currentPeriodUsageURL = URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!

    private let session: URLSession

    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            c.timeoutIntervalForRequest = 15
            return c
        }()
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(cookieHeader: String) async throws -> UsageResponse {
        let data = try await performRequest(url: Self.usageURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    func fetchUsageSummary(cookieHeader: String) async throws -> UsageSummaryResponse {
        let data = try await performRequest(url: Self.usageSummaryURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
    }

    func fetchUserInfo(cookieHeader: String) async throws -> UserInfoResponse {
        let data = try await performRequest(url: Self.userInfoURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(UserInfoResponse.self, from: data)
    }

    /// Lists teams the account belongs to. Used solely to discover a `teamId`
    /// for the analytics endpoint — required on enterprise accounts and
    /// expected to fail (non-200 or empty) on personal plans.
    func fetchTeams(cookieHeader: String) async throws -> TeamsResponse {
        // #89: the endpoint dropped GET support (405 as of 2026-07-18) —
        // POST + bare-host Origin like the other dashboard endpoints.
        let data = try await performRequest(
            url: Self.teamsURL,
            cookieHeader: cookieHeader,
            method: "POST",
            body: Data("{}".utf8),
            origin: "https://cursor.com"
        )
        return try JSONDecoder().decode(TeamsResponse.self, from: data)
    }

    /// Fetches one page of usage events from the dashboard. Events are returned
    /// newest-first; callers paginate by incrementing `page` until the oldest
    /// event in a page is older than the desired window (or `totalUsageEventsCount`
    /// is reached).
    ///
    /// Requires the `Origin: https://cursor.com` header — the endpoint enforces
    /// origin checks on POST. Without it the server returns
    /// `{"error":"Invalid origin for state-changing request"}`.
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
        let body = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        let data = try await performRequest(
            url: Self.filteredUsageEventsURL,
            cookieHeader: cookieHeader,
            method: "POST",
            body: body,
            origin: "https://cursor.com"
        )
        return try JSONDecoder().decode(FilteredUsageEventsResponse.self, from: data)
    }

    /// Fetches the team's member-spend roster solely to discover the caller's
    /// numeric `userId`. Required because `/api/auth/me` returns a workos id but
    /// the dashboard endpoint expects the numeric id. Same Origin-header
    /// requirement as the filtered-usage endpoint.
    func fetchTeamSpend(cookieHeader: String, teamId: Int) async throws -> TeamSpendResponse {
        let body = try JSONSerialization.data(withJSONObject: ["teamId": teamId], options: [])
        let data = try await performRequest(
            url: Self.teamSpendURL,
            cookieHeader: cookieHeader,
            method: "POST",
            body: body,
            origin: "https://cursor.com"
        )
        return try JSONDecoder().decode(TeamSpendResponse.self, from: data)
    }

    /// Current-cycle split quota (Cursor Models vs Other Models). Empty body —
    /// `{"teamId":0}` 400s on personal/Ultra. Same Origin requirement as the
    /// other dashboard POSTs.
    func fetchCurrentPeriodUsage(cookieHeader: String) async throws -> CurrentPeriodUsageResponse {
        let data = try await performRequest(
            url: Self.currentPeriodUsageURL,
            cookieHeader: cookieHeader,
            method: "POST",
            body: Data("{}".utf8),
            origin: "https://cursor.com"
        )
        return try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: data)
    }

    /// Member-facing monthly spend limit for token-based enterprise contracts.
    /// Requires `teamId` — an empty body yields `{noUsageBasedAllowed:true}`
    /// (all fields nil). Same bare-host + Origin requirement as the other
    /// dashboard POST endpoints. Expected to be absent on non-usage-based plans.
    func fetchHardLimit(cookieHeader: String, teamId: Int) async throws -> HardLimitResponse {
        let body = try JSONSerialization.data(withJSONObject: ["teamId": teamId], options: [])
        let data = try await performRequest(
            url: Self.hardLimitURL,
            cookieHeader: cookieHeader,
            method: "POST",
            body: body,
            origin: "https://cursor.com"
        )
        return try JSONDecoder().decode(HardLimitResponse.self, from: data)
    }

    private func performRequest(
        url: URL,
        cookieHeader: String,
        method: String = "GET",
        body: Data? = nil,
        origin: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(
                NSError(domain: "CursorMeter", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        logSetCookieIfPresent(httpResponse)

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        if httpResponse.statusCode == 403 {
            throw APIError.forbidden
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        // Cursor answers an invalid/expired session with 204 No Content on
        // /api/auth/me instead of 401 (verified 2026-07-03). Every endpoint
        // here decodes JSON, so a 2xx with an empty body can never be a
        // success — treat it as the session-expiry signal it is (#76).
        if httpResponse.statusCode == 204 || data.isEmpty {
            throw APIError.unauthorized
        }

        return data
    }

    // MARK: - Set-Cookie rotation diagnostic (#84)

    private var lastSetCookieLogAt: Date?

    /// If the server tries to rotate the session cookie, that explains rapid
    /// expiries: the app keeps sending its statically captured cookie and the
    /// superseded token gets invalidated server-side. Error level so entries
    /// survive log retention; throttled to once per hour to bound noise.
    private func logSetCookieIfPresent(_ response: HTTPURLResponse) {
        guard let summary = Self.setCookieSummary(fromHeaders: response.allHeaderFields) else { return }
        let now = Date()
        if let last = lastSetCookieLogAt, now.timeIntervalSince(last) < 3600 { return }
        lastSetCookieLogAt = now
        Log.error("API response carried Set-Cookie [names only: \(summary)] — possible session rotation (#84)")
    }

    /// Extracts only cookie NAMES from a Set-Cookie header — values are
    /// session tokens and must never reach the log. Pure for testability.
    /// URLSession comma-joins multiple Set-Cookie headers; a new cookie name
    /// appears at string start or after ", ", followed by `=`. Attribute
    /// pairs (`; Path=/`) and Expires dates (`, 15 Jul 2026`) don't match.
    nonisolated static func setCookieSummary(fromHeaders headers: [AnyHashable: Any]) -> String? {
        guard let raw = headers["Set-Cookie"] as? String, !raw.isEmpty else { return nil }
        let pattern = #"(?:^|, )([A-Za-z0-9_\-\.]+)="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        var names: [String] = []
        for match in regex.matches(in: raw, range: range) {
            if let r = Range(match.range(at: 1), in: raw) {
                let name = String(raw[r])
                if !names.contains(name) { names.append(name) }
            }
        }
        return names.isEmpty ? nil : names.joined(separator: ",")
    }
}
