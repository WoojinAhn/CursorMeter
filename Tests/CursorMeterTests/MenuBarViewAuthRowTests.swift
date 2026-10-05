import AppKit
import XCTest
@testable import CursorMeter

/// #94: updateUI must not rebuild the auth-row button when its derived state
/// (visibility + title) is unchanged — every refresh was recreating it, even
/// with the popover closed.
@MainActor
final class MenuBarViewAuthRowTests: XCTestCase {

    private func makeVC(vm: UsageViewModel) -> MenuBarPopoverViewController {
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        return vc
    }

    func test_updateUI_sameAuthState_keepsSameButtonInstance() {
        let vm = makeTestUsageViewModel()
        vm.authState = .loggedIn
        let vc = makeVC(vm: vm)
        vc.updateUI()
        let first = vc.testHook_authRowButton()
        XCTAssertNotNil(first)

        vc.updateUI()

        XCTAssertTrue(vc.testHook_authRowButton() === first,
                      "unchanged auth state must not rebuild the auth row button")
    }

    func test_updateUI_authStateChange_rebuildsButton() {
        let vm = makeTestUsageViewModel()
        vm.authState = .loggedIn
        let vc = makeVC(vm: vm)
        vc.updateUI()
        XCTAssertEqual(vc.testHook_authRowButton()?.title, "Log Out")

        vm.authState = .loggedOut
        vm.browserLoginEnabled = true   // keeps the row visible while logged out
        vc.updateUI()

        XCTAssertEqual(vc.testHook_authRowButton()?.title, "Log in with Browser... (deprecated)")
    }

    func test_updateUI_hiddenThenLoggedIn_showsLogOut() {
        let vm = makeTestUsageViewModel()
        vm.authState = .loggedOut
        vm.browserLoginEnabled = false   // hidden: IDE presumed installed (#90)
        let vc = makeVC(vm: vm)
        vc.updateUI()
        XCTAssertNil(vc.testHook_authRowButton())

        vm.authState = .loggedIn
        vc.updateUI()

        XCTAssertEqual(vc.testHook_authRowButton()?.title, "Log Out")
    }
}
