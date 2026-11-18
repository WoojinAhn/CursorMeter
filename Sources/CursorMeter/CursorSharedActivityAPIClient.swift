import Foundation

protocol CursorSharedActivityFetching: Sendable {
    func fetchRecent(cookieHeader: String, start: Date, end: Date) async throws -> SharedBillingItemsResponse
    func fetchDaily(cookieHeader: String, start: Date, end: Date) async throws -> SharedDailyUsageResponse
    func fetchStatus(cookieHeader: String) async throws -> SharedUsageStatusResponse
}

final class CursorSharedActivityAPIClient: CursorSharedActivityFetching {
    private let session: URLSession
    private static let responseLimit = 1_048_576

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let protocols = configuration.protocolClasses
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocols
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration, delegate: SharedActivityRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func fetchRecent(cookieHeader: String, start: Date, end: Date) async throws -> SharedBillingItemsResponse {
        try await fetch("query-billing-items", cookieHeader: cookieHeader, query: [
            .init(name: "scope", value: "user"), .init(name: "startTime", value: Self.timestamp(start)),
            .init(name: "endTime", value: Self.timestamp(end)), .init(name: "pageSize", value: "30")])
    }

    func fetchDaily(cookieHeader: String, start: Date, end: Date) async throws -> SharedDailyUsageResponse {
        let body = try JSONSerialization.data(withJSONObject: ["scope": "user", "startTime": Self.timestamp(start),
            "endTime": Self.timestamp(end), "groupBy": ["usageType"], "filters": [:] as [String: String], "topN": 20])
        return try await fetch("query-daily-usage", cookieHeader: cookieHeader, body: body)
    }

    func fetchStatus(cookieHeader: String) async throws -> SharedUsageStatusResponse {
        try await fetch("usage-status", cookieHeader: cookieHeader, query: [.init(name: "scope", value: "user")])
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func fetch<T: Decodable & Sendable>(_ path: String, cookieHeader: String,
                                                query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        do {
            try Task.checkCancellation()
            guard !cookieHeader.isEmpty,
                  !cookieHeader.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CursorSharedAPIError.invalidCredential
            }
            var components = URLComponents(string: "https://cursor.com/api/dashboard/v2/" + path)!
            if !query.isEmpty { components.queryItems = query }
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = body
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("v2", forHTTPHeaderField: "x-cursor-dashboard-surface")
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw CursorSharedAPIError.invalidResponse }
            switch response.statusCode {
            case 200...299: break
            case 401: throw CursorSharedAPIError.unauthorized
            case 403: throw CursorSharedAPIError.forbidden
            default: throw CursorSharedAPIError.httpStatus(response.statusCode)
            }
            guard response.expectedContentLength <= Self.responseLimit else { throw CursorSharedAPIError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.responseLimit else { throw CursorSharedAPIError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard !data.isEmpty else { throw CursorSharedAPIError.emptyResponse }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw CursorSharedAPIError.invalidResponse }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CursorSharedAPIError.cancelled }
            throw error as? CursorSharedAPIError ?? .transport
        }
    }
}

private final class SharedActivityRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
