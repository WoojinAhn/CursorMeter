import XCTest
@testable import CursorMeter

final class CircularProgressIconTests: XCTestCase {

    // MARK: - ProgressLevel

    func testLevelNormalAt0() {
        XCTAssertEqual(CircularProgressIcon.level(for: 0), .normal)
    }

    func testLevelNormalAt69() {
        XCTAssertEqual(CircularProgressIcon.level(for: 69.9), .normal)
    }

    func testLevelWarningAt70() {
        XCTAssertEqual(CircularProgressIcon.level(for: 70), .warning)
    }

    func testLevelWarningAt89() {
        XCTAssertEqual(CircularProgressIcon.level(for: 89.9), .warning)
    }

    func testLevelCriticalAt90() {
        XCTAssertEqual(CircularProgressIcon.level(for: 90), .critical)
    }

    func testLevelCriticalAt100() {
        XCTAssertEqual(CircularProgressIcon.level(for: 100), .critical)
    }

    func testLevelNormalNegative() {
        XCTAssertEqual(CircularProgressIcon.level(for: -10), .normal)
    }

    func testLevelCriticalOver100() {
        XCTAssertEqual(CircularProgressIcon.level(for: 150), .critical)
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
}
