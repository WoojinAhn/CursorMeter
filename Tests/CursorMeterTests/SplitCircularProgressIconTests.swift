import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class SplitCircularProgressIconTests: XCTestCase {
    func testIconOnlyUsesRequestedSize() {
        let standard = CircularProgressIcon.makeSplitImage(cursorPercent: 25, otherPercent: 75)
        XCTAssertEqual(standard.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(standard.isTemplate)
        let larger = CircularProgressIcon.makeSplitImage(
            cursorPercent: 25, otherPercent: 75, size: NSSize(width: 20, height: 20))
        XCTAssertEqual(larger.size, NSSize(width: 20, height: 20))
    }

    func testSwapMovesIdentitiesWithoutChangingValues() throws {
        let defaultImage = CircularProgressIcon.makeSplitImage(cursorPercent: 25, otherPercent: 90)
        let explicitlyOther = CircularProgressIcon.makeSplitImage(
            cursorPercent: 25, otherPercent: 90, outerPool: .other)
        let swapped = CircularProgressIcon.makeSplitImage(
            cursorPercent: 25, otherPercent: 90, outerPool: .cursor)
        let equivalent = CircularProgressIcon.makeSplitImage(cursorPercent: 90, otherPercent: 25)
        XCTAssertEqual(try pixels(defaultImage), try pixels(explicitlyOther))
        XCTAssertEqual(try pixels(swapped), try pixels(equivalent))
        XCTAssertNotEqual(try pixels(defaultImage), try pixels(swapped))
    }

    func testZeroHasVisibleTrackAndMissingIsDistinctInBothRegions() throws {
        let zero = CircularProgressIcon.makeSplitImage(cursorPercent: 0, otherPercent: 0)
        let missingCenter = CircularProgressIcon.makeSplitImage(cursorPercent: nil, otherPercent: 0)
        let missingOuter = CircularProgressIcon.makeSplitImage(cursorPercent: 0, otherPercent: nil)
        XCTAssertTrue(try pixels(zero).contains { $0 != 0 })
        XCTAssertNotEqual(try pixels(zero), try pixels(missingCenter))
        XCTAssertNotEqual(try pixels(zero), try pixels(missingOuter))
        XCTAssertNotEqual(try pixels(missingCenter), try pixels(missingOuter))
    }

    func testGeometryClampsOverOneHundredAndRejectsInvalidValues() throws {
        let full = CircularProgressIcon.makeSplitImage(cursorPercent: 100, otherPercent: 100)
        let exceeded = CircularProgressIcon.makeSplitImage(cursorPercent: 135, otherPercent: 200)
        XCTAssertEqual(try pixels(full), try pixels(exceeded))
        let missing = CircularProgressIcon.makeSplitImage(cursorPercent: nil, otherPercent: nil)
        for value in [Double.nan, .infinity, -1] {
            let invalid = CircularProgressIcon.makeSplitImage(cursorPercent: value, otherPercent: value)
            XCTAssertEqual(try pixels(missing), try pixels(invalid))
        }
    }

    func testIndependentFilledCenterAndOuterRingRemainSeparated() throws {
        let bitmap = try bitmap(CircularProgressIcon.makeSplitImage(cursorPercent: 100, otherPercent: 100))
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 36, y: 36)).alphaComponent, 0.9)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 36, y: 11)).alphaComponent, 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 36, y: 5)).alphaComponent, 0.9)
    }

    func testTracksRenderInLightAndDarkAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var data: [UInt8] = []
            let appearance: NSAppearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                data = (try? pixels(CircularProgressIcon.makeSplitImage(cursorPercent: 0, otherPercent: nil))) ?? []
            }
            XCTAssertTrue(data.contains { $0 != 0 }, "Expected visible geometry in \(name)")
        }
    }

    private func pixels(_ image: NSImage) throws -> [UInt8] {
        let bitmap = try bitmap(image)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        image.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
        return bitmap
    }
}
