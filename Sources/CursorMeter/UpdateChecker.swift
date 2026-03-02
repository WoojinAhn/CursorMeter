import Foundation

@MainActor
final class UpdateChecker: Sendable {
    struct Release: Sendable {
        let tagName: String
        let htmlURL: String
        let version: String
    }

    static let shared = UpdateChecker()
    private init() {}

    private static let releasesURL = URL(string: "https://api.github.com/repos/WoojinAhn/CursorMeter/releases/latest")!

    func check() async -> Release? {
        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else { return nil }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String
            else { return nil }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = currentAppVersion()

            guard isNewer(remote: remoteVersion, current: currentVersion) else {
                Log.info("App is up to date (current: \(currentVersion), latest: \(remoteVersion))")
                return nil
            }

            Log.info("Update available: \(currentVersion) → \(remoteVersion)")
            return Release(tagName: tagName, htmlURL: htmlURL, version: remoteVersion)
        } catch {
            Log.error("Update check failed: \(error)")
            return nil
        }
    }

    private func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Simple semver comparison: returns true if remote > current
    func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }
}
