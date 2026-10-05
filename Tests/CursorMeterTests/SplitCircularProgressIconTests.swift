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
        try assertPixels(defaultImage, explicitlyOther, areEqual: true)
        try assertPixels(swapped, equivalent, areEqual: true)
        try assertPixels(defaultImage, swapped, areEqual: false)
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

    func testTodayDefaultAndKnownZeroPreserveOriginalRendering() throws {
        let original = CircularProgressIcon.makeSplitImage(cursorPercent: 12, otherPercent: 42)
        for points: [UsagePoolID: Double] in [[:], [.cursor: 0, .other: 0]] {
            let image = CircularProgressIcon.makeSplitImage(
                cursorPercent: 12, otherPercent: 42, todayPercentagePoints: points)
            XCTAssertEqual(try pixels(original), try pixels(image))
        }
    }

    func testTodayPortionsFollowPoolWhenPlacementSwaps() throws {
        let swapped = CircularProgressIcon.makeSplitImage(
            cursorPercent: 12, otherPercent: 42, outerPool: .cursor,
            todayPercentagePoints: [.cursor: 4, .other: 8])
        let equivalent = CircularProgressIcon.makeSplitImage(
            cursorPercent: 42, otherPercent: 12,
            todayPercentagePoints: [.cursor: 8, .other: 4])
        XCTAssertEqual(try pixels(swapped), try pixels(equivalent))
    }

    func testTodayOccupiesTheEndingAngleAndDividerIsAtTheSharedBoundary() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        try withAppearance(appearance) {
            let original = try bitmap(CircularProgressIcon.makeSplitImage(cursorPercent: 42, otherPercent: 42))
            let highlighted = try bitmap(CircularProgressIcon.makeSplitImage(
                cursorPercent: 42, otherPercent: 42,
                todayPercentagePoints: [.cursor: 8, .other: 8]))
            // Independent samples: 20% is earlier, 38% is today, 34% is their boundary.
            for radius in [15.0, 30.0] {
                func color(_ image: NSBitmapImageRep, at fraction: Double) throws -> NSColor {
                    let angle = fraction * 2 * Double.pi
                    return try XCTUnwrap(image.colorAt(
                        x: Int((36 + sin(angle) * radius).rounded()),
                        y: Int((36 - cos(angle) * radius).rounded()))?.usingColorSpace(.deviceRGB))
                }
                XCTAssertEqual(try color(highlighted, at: 0.20), try color(original, at: 0.20))
                XCTAssertGreaterThan(try color(highlighted, at: 0.38).redComponent,
                                     try color(original, at: 0.38).redComponent + 0.1)
                XCTAssertLessThan(try color(highlighted, at: 0.34).greenComponent,
                                  try color(original, at: 0.34).greenComponent - 0.1)
            }
        }
    }

    func testInvalidTodayInputAndSpilloverCannotExtendTheFill() throws {
        let original = CircularProgressIcon.makeSplitImage(cursorPercent: 12, otherPercent: 42)
        for invalid in [-1, Double.nan, .infinity, 43] {
            let image = CircularProgressIcon.makeSplitImage(
                cursorPercent: 12, otherPercent: 42, todayPercentagePoints: [.other: invalid])
            XCTAssertEqual(try pixels(original), try pixels(image))
        }
        for (cursor, other) in [(100.0, 42.0), (12.0, 101.0)] {
            let baseline = CircularProgressIcon.makeSplitImage(cursorPercent: cursor, otherPercent: other)
            let image = CircularProgressIcon.makeSplitImage(
                cursorPercent: cursor, otherPercent: other,
                todayPercentagePoints: [.cursor: 4, .other: 8])
            XCTAssertEqual(try pixels(baseline), try pixels(image))
        }
    }

    func testTodayKeepsTrackAndSeparationAcrossSeverityAndAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua,
                     .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            try withAppearance(appearance) {
                for percent in [42.0, 75.0, 95.0] {
                    let original = try bitmap(CircularProgressIcon.makeSplitImage(
                        cursorPercent: percent, otherPercent: percent))
                    let highlighted = try bitmap(CircularProgressIcon.makeSplitImage(
                        cursorPercent: percent, otherPercent: percent,
                        todayPercentagePoints: [.cursor: 8, .other: 8]))
                    var changed = 0
                    for y in 0..<72 {
                        for x in 0..<72 {
                            let before = try XCTUnwrap(original.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            let after = try XCTUnwrap(highlighted.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if before != after { changed += 1 }
                            if before.alphaComponent == 0 {
                                XCTAssertEqual(after.alphaComponent, 0, "Outside geometry changed at \(x),\(y)")
                            }
                            if before.alphaComponent > 0.1,
                               before.redComponent == before.greenComponent,
                               before.greenComponent == before.blueComponent {
                                XCTAssertEqual(after, before, "Unused track changed at \(x),\(y)")
                            }
                        }
                    }
                    XCTAssertGreaterThan(changed, 0, "Expected today color in \(name), \(percent)")
                }
            }
        }
        if let directory = ProcessInfo.processInfo.environment["CM_UI_ARTIFACT_DIR"] {
            try exportTodayAppearanceMatrix(to: directory)
        }
    }

    func testTinyAndAlmostAllTodayDoNotReceiveAnOverpoweringDivider() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        try withAppearance(appearance) {
            let original = try bitmap(CircularProgressIcon.makeSplitImage(cursorPercent: 42, otherPercent: 42))
            for (today, expectsDivider) in [(0.2, false), (41.8, false), (42.0, false), (8.0, true)] {
                let highlighted = try bitmap(CircularProgressIcon.makeSplitImage(
                    cursorPercent: 42, otherPercent: 42,
                    todayPercentagePoints: [.cursor: today, .other: today]))
                var darkenedInterior = false
                for y in 0..<72 {
                    for x in 0..<72 {
                        let before = try XCTUnwrap(original.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        let after = try XCTUnwrap(highlighted.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if before.alphaComponent > 0.99,
                           after.greenComponent + 0.02 < before.greenComponent {
                            darkenedInterior = true
                        }
                    }
                }
                XCTAssertEqual(darkenedInterior, expectsDivider, "Today = \(today)pp")
            }
        }
    }

    private func withAppearance(_ appearance: NSAppearance, _ body: () throws -> Void) throws {
        var failure: Error?
        appearance.performAsCurrentDrawingAppearance {
            do { try body() } catch { failure = error }
        }
        if let failure { throw failure }
    }

    private func exportTodayAppearanceMatrix(to directory: String) throws {
        let names: [(String, NSAppearance.Name)] = [
            ("Light", .aqua), ("Dark", .darkAqua),
            ("High contrast light", .accessibilityHighContrastAqua),
            ("High contrast dark", .accessibilityHighContrastDarkAqua),
        ]
        let appearances = try names.map { try XCTUnwrap(NSAppearance(named: $0.1)) }
        let matrix = NSImage(size: NSSize(width: 600, height: 465), flipped: false) { _ in
            for (column, appearance) in appearances.enumerated() {
                appearance.performAsCurrentDrawingAppearance {
                    for (row, percent) in [42.0, 75.0, 95.0].enumerated() {
                        let cell = NSRect(x: column * 150, y: (2 - row) * 155, width: 150, height: 155)
                        NSColor.windowBackgroundColor.setFill()
                        cell.fill()
                        CircularProgressIcon.makeSplitImage(
                            cursorPercent: percent, otherPercent: percent, size: NSSize(width: 112, height: 112),
                            todayPercentagePoints: [.cursor: 8, .other: 8])
                            .draw(in: NSRect(x: cell.minX + 19, y: cell.minY + 30, width: 112, height: 112))
                        let label = NSAttributedString(string: "\(names[column].0) · \(Int(percent))%", attributes: [
                            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor,
                        ])
                        label.draw(at: NSPoint(x: cell.midX - label.size().width / 2, y: cell.minY + 10))
                    }
                }
            }
            return true
        }
        let png = try XCTUnwrap(matrix.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("today-appearance-matrix.png"))
    }

    private func assertPixels(
        _ actualImage: NSImage, _ expectedImage: NSImage, areEqual: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let actual = try pixels(actualImage)
        let expected = try pixels(expectedImage)
        guard (actual == expected) != areEqual else { return }
        let sizes = "Image sizes: \(actualImage.size) / \(expectedImage.size); buffer sizes: \(actual.count) / \(expected.count) bytes."
        if areEqual {
            let difference = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
            let detail = difference.map {
                "First difference at byte \($0.offset): \($0.element.0) / \($0.element.1)."
            } ?? "All \(min(actual.count, expected.count)) shared bytes match."
            XCTFail("Expected equal pixels. \(sizes) \(detail)", file: file, line: line)
        } else {
            XCTFail("Expected different pixels. \(sizes) All pixels match.", file: file, line: line)
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
