import Foundation

enum APIError: Error {
    case unauthorized
    case forbidden
    case httpError(statusCode: Int)
    case networkError(Error)
}

actor CursorAPIClient {
    private static let usageURL = URL(string: "https://www.cursor.com/api/usage")!
    private static let userInfoURL = URL(string: "https://www.cursor.com/api/auth/me")!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(cookieHeader: String) async throws -> UsageResponse {
        let data = try await performRequest(url: Self.usageURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    func fetchUserInfo(cookieHeader: String) async throws -> UserInfoResponse {
        let data = try await performRequest(url: Self.userInfoURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(UserInfoResponse.self, from: data)
    }

    private func performRequest(url: URL, cookieHeader: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(
                NSError(domain: "CursorBar", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        if httpResponse.statusCode == 403 {
            throw APIError.forbidden
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }
}
