import Foundation

protocol CursorSharedUsageFetching: Sendable {
    func fetchPlanInfo(cookieHeader: String) async throws -> CursorPlanInfoResponse
    func fetchCurrentPeriod(cookieHeader: String) async throws -> CurrentPeriodUsageResponse
    func fetchPrepaid(cookieHeader: String) async throws -> CursorPrepaidBillingResponse
    func fetchPaidCap(cookieHeader: String) async throws -> CursorPaidCapResponse
}

enum CursorSharedAPIError: Error, Equatable, Sendable {
    case invalidCredential, unauthorized, forbidden, identityUnlinked
    case httpStatus(Int)
    case emptyResponse, invalidResponse, responseTooLarge
    case transport, cancelled
}

final class CursorSharedAPIClient: CursorSharedUsageFetching {
    private let session: URLSession
    private static let responseLimit = 1_048_576

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let protocolClasses = configuration.protocolClasses
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration, delegate: CursorSharedRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func fetchPlanInfo(cookieHeader: String) async throws -> CursorPlanInfoResponse {
        try await fetch(.planInfo, cookieHeader: cookieHeader)
    }

    func fetchCurrentPeriod(cookieHeader: String) async throws -> CurrentPeriodUsageResponse {
        try await fetch(.currentPeriod, cookieHeader: cookieHeader)
    }

    func fetchPrepaid(cookieHeader: String) async throws -> CursorPrepaidBillingResponse {
        try await fetch(.prepaid, cookieHeader: cookieHeader)
    }

    func fetchPaidCap(cookieHeader: String) async throws -> CursorPaidCapResponse {
        try await fetch(.paidCap, cookieHeader: cookieHeader)
    }

    private enum RPC: String {
        case planInfo = "GetPlanInfo"
        case currentPeriod = "GetCurrentPeriodUsage"
        case prepaid = "GetUserPrepaidBilling"
        case paidCap = "GetHardLimit"

        var body: Data {
            Data((self == .currentPeriod || self == .paidCap ? #"{"personalScope":true}"# : "{}").utf8)
        }
    }

    private func fetch<Response: Decodable & Sendable>(_ rpc: RPC, cookieHeader: String) async throws -> Response {
        do {
            try Task.checkCancellation()
            let token = try Self.accessToken(from: cookieHeader)
            let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/" + rpc.rawValue)!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.httpBody = rpc.body
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
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
            do { return try JSONDecoder().decode(Response.self, from: data) }
            catch { throw CursorSharedAPIError.invalidResponse }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CursorSharedAPIError.cancelled
            }
            if let error = error as? CursorSharedAPIError { throw error }
            throw CursorSharedAPIError.transport
        }
    }

    private static func accessToken(from header: String) throws -> String {
        guard !header.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CursorSharedAPIError.invalidCredential
        }
        let values = header.split(separator: ";", omittingEmptySubsequences: false).compactMap { item -> String? in
            let item = item.drop(while: { $0 == " " })
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.first == "WorkosCursorSessionToken" else { return nil }
            guard pair.count == 2 else { return "" }
            return String(pair[1])
        }
        guard values.count == 1, let raw = values.first, validPercentEncoding(raw),
              let value = raw.removingPercentEncoding,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CursorSharedAPIError.invalidCredential
        }
        let parts = value.components(separatedBy: "::")
        guard parts.count == 2, !parts[0].isEmpty else { throw CursorSharedAPIError.invalidCredential }
        let token = parts[1]
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = base64URL(segments[0]), let payloadData = base64URL(segments[1]), base64URL(segments[2]) != nil,
              let jwtHeader = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let algorithm = jwtHeader["alg"] as? String, !algorithm.isEmpty, algorithm.lowercased() != "none",
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let subject = payload["sub"] as? String,
              let userID = CursorAppAuthReader.userID(fromSub: subject) ?? (subject.contains("|") ? nil : subject),
              userID == parts[0],
              let expiry = payload["exp"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue.isFinite, expiry.doubleValue > Date().timeIntervalSince1970 else {
            throw CursorSharedAPIError.invalidCredential
        }
        return token
    }

    private static func validPercentEncoding(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count,
                      bytes[(index + 1)...(index + 2)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }

    private static func base64URL(_ segment: Substring) -> Data? {
        guard !segment.isEmpty,
              segment.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var encoded = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }
}

private final class CursorSharedRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
