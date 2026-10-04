import Foundation
import XCTest
@testable import CursorMeter

final class SplitMenuBarPresentationTests: XCTestCase {
    func testVisibilityRequiresAllFourGates() {
        let presentation = SplitUsagePresentation.make(snapshot: snapshot(cursor: 12, other: 42))
        for mask in 0..<16 {
            let result = SplitMenuBarReadout.make(
                enabled: mask & 1 != 0, isLoggedIn: mask & 2 != 0,
                hasUsageData: mask & 4 != 0, suppressesLegacyMeter: mask & 8 != 0,
                presentation: presentation)
            XCTAssertEqual(result != nil, mask == 15, "Visibility mask: \(mask)")
        }
    }

    func testRowsFollowOuterAndCenterPoolOrder() {
        for outer in UsagePoolID.allCases {
            let presentation = SplitUsagePresentation.make(
                snapshot: snapshot(cursor: 12, other: 42), outerPool: outer)
            XCTAssertEqual(readout(presentation), SplitMenuBarReadout(
                upper: outer == .other ? "42.0%" : "12.0%",
                lower: outer == .other ? "12.0%" : "42.0%"))
        }
    }

    func testMissingPresentationKeepsTwoUnavailableRows() {
        XCTAssertEqual(readout(nil), SplitMenuBarReadout(upper: "—", lower: "—"))
    }

    func testPartialPoolValuesRemainInTheirRows() {
        XCTAssertEqual(readout(SplitUsagePresentation.make(snapshot: snapshot(cursor: nil, other: 42))),
                       SplitMenuBarReadout(upper: "42.0%", lower: "—"))
        XCTAssertEqual(readout(SplitUsagePresentation.make(snapshot: snapshot(cursor: 12, other: nil))),
                       SplitMenuBarReadout(upper: "—", lower: "12.0%"))
    }

    func testBoundaryStringsPassThroughExistingFormatter() {
        let cases: [(Double?, String)] = [
            (nil, "—"), (.nan, "—"), (.infinity, "—"), (-1, "—"),
            (0, "0.0%"), (0.001, "<0.1%"), (0.1, "0.1%"),
            (99.95, "<100.0%"), (100, "100.0%"), (100.01, ">100.0%"),
            (135.25, "135.3%"),
        ]
        for (value, expected) in cases {
            let result = readout(SplitUsagePresentation.make(snapshot: snapshot(cursor: value, other: value)))
            XCTAssertEqual(result, SplitMenuBarReadout(upper: expected, lower: expected))
        }
    }

    func testPopoverValueModeDoesNotChangeMenuBarPercentages() {
        for mode in PopoverValueMode.allCases {
            let presentation = SplitUsagePresentation.make(
                snapshot: snapshot(cursor: 12, other: 42), valueMode: mode)
            XCTAssertEqual(readout(presentation), SplitMenuBarReadout(upper: "42.0%", lower: "12.0%"))
        }
    }

    private func readout(_ presentation: SplitUsagePresentation?) -> SplitMenuBarReadout? {
        SplitMenuBarReadout.make(enabled: true, isLoggedIn: true, hasUsageData: true,
                                suppressesLegacyMeter: true, presentation: presentation)
    }

    private func snapshot(cursor: Double?, other: Double?) -> SplitUsageSnapshot {
        SplitUsageSnapshot(
            identity: UsageRevisionIdentity(
                localID: 2, credentialGeneration: 1, accountDigest: "test-account",
                scopeDigest: "test-scope", cycle: UsageCycle(
                    start: Date(timeIntervalSince1970: 1_788_220_800),
                    end: Date(timeIntervalSince1970: 1_790_812_800)), planIdentity: "test-plan"),
            capturedAt: Date(timeIntervalSince1970: 1_790_416_800),
            cursorPercent: cursor, otherPercent: other, includedUsedCents: 18200)
    }
}
