import AppKit
import XCTest
@testable import CursorMeter

/// #87 regression: no dynamic popover row may demand more width from
/// AutoLayout than the fixed inner width (260pt container − 2×10pt padding).
/// The stale-data label (#77) had an unbounded intrinsic width (~261.5pt),
/// which inflated the content view past the popover window frame and clipped
/// the right edge until app restart.
@MainActor
final class MenuBarViewLayoutTests: XCTestCase {

    /// Inner content width available to rootStack.
    private static let innerWidth: CGFloat = 240

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private static let successHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let url = request.url!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        switch url.path {
        case "/api/usage-summary":
            let json = """
            {
                "billingCycleStart": "2026-03-01T07:29:44.000Z",
                "billingCycleEnd": "2026-04-01T07:29:44.000Z",
                "membershipType": "enterprise",
                "limitType": "team",
                "isUnlimited": false,
                "individualUsage": {
                    "plan": { "enabled": true, "used": 8, "limit": 2000, "remaining": 1992, "totalPercentUsed": 0.1 },
                    "onDemand": { "enabled": true, "used": 0, "limit": 2000, "remaining": 2000 }
                },
                "teamUsage": {
                    "onDemand": { "enabled": true, "used": 0, "limit": 120000, "remaining": 120000 }
                }
            }
            """
            return (ok, Data(json.utf8))
        case "/api/auth/me":
            return (ok, Data("{\"email\":\"t@t.com\",\"name\":\"T\"}".utf8))
        case "/api/usage":
            return (ok, Data("{\"startOfMonth\":\"2026-07-01T00:00:00.000Z\"}".utf8))
        default:
            let serverError = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (serverError, Data("oops".utf8))
        }
    }

    private static let serverErrorHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let serverError = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (serverError, Data("oops".utf8))
    }

    func test_fiveDigitAmountsFitWithoutShrinkingRefreshTarget() throws {
        func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }
        for onDemand in [false, true] {
            let data = UsageDisplayData(
                email: "demo@example.com", name: "Demo User", membershipType: nil,
                planUsedCents: onDemand ? 2_000 : 1_234_567,
                planLimitCents: onDemand ? 2_000 : 2_000_000,
                serverPercentUsed: nil, requestsUsed: 0, requestsLimit: 0,
                onDemandUsedCents: onDemand ? 1_234_567 : nil,
                onDemandLimitCents: onDemand ? 2_000_000 : nil,
                onDemandEnabled: onDemand ? true : nil,
                isOnDemandActive: false, cycleStartDate: nil, resetDate: nil
            )
            XCTAssertEqual(data.wouldActivateOnDemand, onDemand)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
            vm.updateCheckRunner = { .upToDate }
            vm.authState = .loggedIn
            vm.usageData = data.withOnDemandActive(data.wouldActivateOnDemand)
            let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
            _ = vc.view
            vc.updateUI()
            let window = NSWindow(contentViewController: vc)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 260, height: vc.view.fittingSize.height))
            vc.view.layoutSubtreeIfNeeded()
            defer { window.contentViewController = nil; window.close() }

            let views = descendants(of: vc.view)
            let labels = views.compactMap { $0 as? NSTextField }
            let amount = try XCTUnwrap(labels.first { $0.stringValue == "$12345.67 / $20000.00" })
            let title = try XCTUnwrap(labels.first { $0.stringValue == (onDemand ? "On-demand" : "Plan Usage") })
            let button = try XCTUnwrap(views.compactMap { $0 as? RefreshFeedbackButton }.first)
            XCTAssertLessThanOrEqual(vc.testHook_contentFittingWidth(), Self.innerWidth)
            XCTAssertGreaterThanOrEqual(amount.alignmentRect(forFrame: amount.frame).width + 0.01,
                                       amount.intrinsicContentSize.width)
            XCTAssertLessThan(title.alignmentRect(forFrame: title.frame).width, title.intrinsicContentSize.width)
            XCTAssertEqual(title.lineBreakMode, .byTruncatingTail)
            for view in [amount as NSView, button as NSView] {
                let parent = try XCTUnwrap(view.superview)
                let frame = parent.convert(view.alignmentRect(forFrame: view.frame), to: vc.view)
                XCTAssertGreaterThanOrEqual(frame.minX, 10)
                XCTAssertLessThanOrEqual(frame.maxX, 250)
            }
            XCTAssertEqual(button.frame.width, 26, accuracy: 0.01)
            XCTAssertEqual(button.frame.height, 24, accuracy: 0.01)
        }
    }

    /// Stale row visible with a realistic worst-case message must not push the
    /// content's fitting width past the available inner width.
    func test_staleRowVisible_contentFittingWidth_staysWithinInnerWidth() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(
            apiClient: CursorAPIClient(configuration: config),
            refreshFeedback: RefreshFeedback(timing: .immediate)
        )
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}  // UNUserNotificationCenter crashes in SPM tests
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        vm.authState = .loggedIn

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()
        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<UsageViewModel.staleThreshold {
            await vm.refresh()
        }
        XCTAssertTrue(vm.isDataStale, "fixture must reach the stale state")

        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()

        XCTAssertLessThanOrEqual(
            vc.testHook_contentFittingWidth(), Self.innerWidth,
            "stale label must truncate instead of widening the popover content (#87)"
        )
    }
}
