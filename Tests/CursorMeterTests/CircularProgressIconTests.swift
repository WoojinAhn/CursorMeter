import XCTest
@testable import CursorMeter

final class CircularProgressIconTests: XCTestCase {

    // MARK: - Token Color

    func testTokenColorNormalAt0() {
        XCTAssertEqual(CircularProgressIcon.tokenColor(for: 0), CircularProgressIcon.accentColor)
    }

    func testTokenColorNormalAt69() {
        XCTAssertEqual(CircularProgressIcon.tokenColor(for: 69.9), CircularProgressIcon.accentColor)
    }

    func testTokenColorWarningAt70() {
        XCTAssertEqual(CircularProgressIcon.tokenColor(for: 70), CircularProgressIcon.warnColor)
    }

    func testTokenColorWarningAt89() {
        XCTAssertEqual(CircularProgressIcon.tokenColor(for: 89.9), CircularProgressIcon.warnColor)
    }

    func testTokenColorCriticalAt90() {
        XCTAssertEqual(CircularProgressIcon.tokenColor(for: 90), CircularProgressIcon.critColor)
    }

    func testTokenColorCriticalAt100() {
        XCTAssertEqual(CircularProgressIcon.tokenColor(for: 100), CircularProgressIcon.critColor)
    }

    func testTokenColorNormalNegative() {
        XCTAssertEqual(CircularProgressIcon.tokenColor(for: -10), CircularProgressIcon.accentColor)
    }

    func testTokenColorCriticalOver100() {
        XCTAssertEqual(CircularProgressIcon.tokenColor(for: 150), CircularProgressIcon.critColor)
    }

    // MARK: - Menu Bar Image

    func testMenuBarImageNotNil() {
        let image = CircularProgressIcon.menuBarImage(percent: 50)
        XCTAssertEqual(image.size.width, 18)
        XCTAssertEqual(image.size.height, 18)
    }

    func testMenuBarImageZeroPercent() {
        let image = CircularProgressIcon.menuBarImage(percent: 0)
        XCTAssertEqual(image.size.width, 18)
    }

    func testMenuBarImageNotTemplate() {
        let image = CircularProgressIcon.menuBarImage(percent: 50)
        XCTAssertFalse(image.isTemplate)
    }

    // MARK: - Menu Bar Image With Text (String)

    func testMenuBarImageWithTextNotNil() {
        let image = CircularProgressIcon.menuBarImageWithText(
            percent: 50, usedText: "150", limitText: "500"
        )
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(image.size.height, 22)
    }

    func testMenuBarImageWithTextCreditFormat() {
        let image = CircularProgressIcon.menuBarImageWithText(
            percent: 25, usedText: "12.5", limitText: "50.0"
        )
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertFalse(image.isTemplate)
    }

    // MARK: - Menu Bar Image With Percent

    func testMenuBarImageWithPercentNotNil() {
        let image = CircularProgressIcon.menuBarImageWithPercent(percent: 75)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(image.size.height, 22)
    }

    func testMenuBarImageWithPercentNotTemplate() {
        let image = CircularProgressIcon.menuBarImageWithPercent(percent: 50)
        XCTAssertFalse(image.isTemplate)
    }

    func testMenuBarImageWithPercentZero() {
        let image = CircularProgressIcon.menuBarImageWithPercent(percent: 0)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    // MARK: - Login Required Image (#76)

    func testLoginRequiredImageIsWiderThanIdle() {
        // Badge overhangs the top-right corner — canvas must grow so it never clips.
        let idle = CircularProgressIcon.idleImage()
        let badged = CircularProgressIcon.loginRequiredImage()
        XCTAssertGreaterThan(badged.size.width, idle.size.width)
        XCTAssertEqual(badged.size.height, idle.size.height)
        XCTAssertFalse(badged.isTemplate)
    }
}
