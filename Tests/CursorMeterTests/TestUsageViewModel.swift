import XCTest
@testable import CursorMeter

@MainActor
func makeTestUsageViewModel(
    apiClient: CursorAPIClient? = nil,
    recentUsage: RecentUsageController? = nil,
    refreshFeedback: RefreshFeedback? = nil,
    notificationManager: NotificationManager? = nil,
    splitUsage: SplitUsageController? = nil,
    splitAlertStore: SplitUsageAlertStore? = nil,
    updateCheckRunner: @escaping @MainActor () async -> UpdateCheckResult = { .upToDate }
) -> UsageViewModel {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UnexpectedViewModelRequestProtocol.self]
    let viewModel = UsageViewModel(
        apiClient: apiClient ?? CursorAPIClient(configuration: configuration),
        recentUsage: recentUsage,
        refreshFeedback: refreshFeedback,
        notificationManager: notificationManager ?? NotificationManager(
            requestAuthorization: { true }, deliver: { _ in }
        ),
        splitUsage: splitUsage,
        splitAlertStore: splitAlertStore
    )
    // The initializer's Task inherits MainActor and cannot run until this
    // synchronous factory returns, after all external-service seams are set.
    viewModel.updateCheckRunner = updateCheckRunner
    viewModel.keychainSaveHandler = { _ in
        XCTFail("Unexpected Keychain save; install a test-specific save handler")
    }
    viewModel.keychainDeleteHandler = {}
    viewModel.sessionExpiredNotifier = {}
    return viewModel
}

private final class UnexpectedViewModelRequestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTFail("Unexpected API request; inject a CursorAPIClient with an explicit test handler")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}
