import AppKit
import CoreText
import XCTest
@testable import CursorMeter

@MainActor
final class SplitMenuBarRendererTests: XCTestCase {
    func testOrdinaryAndBoundaryValuesReserveStableGeometry() {
        let baseline = SplitMenuBarRenderer.layout(readout: .init(upper: "0.0%", lower: "—"))
        for text in ["0.0%", "9.9%", "99.9%", "100.0%", "<0.1%", "<100.0%", ">100.0%", "135.3%", "—"] {
            let layout = SplitMenuBarRenderer.layout(readout: .init(upper: text, lower: text))
            XCTAssertEqual(layout.size, baseline.size, text)
            XCTAssertEqual(layout.size.height, 22)
            XCTAssertEqual(layout.iconRect, NSRect(x: 0, y: 2, width: 18, height: 18))
            XCTAssertEqual(layout.upperRowRect.minX - layout.iconRect.maxX, 4)
            XCTAssertEqual(layout.upperRowRect.height, 11)
            XCTAssertEqual(layout.lowerRowRect.height, 11)
            XCTAssertEqual(layout.upperRowRect.minY, layout.lowerRowRect.maxY)
            XCTAssertTrue(layout.upperRowRect.contains(layout.upperInkBounds), text)
            XCTAssertTrue(layout.lowerRowRect.contains(layout.lowerInkBounds), text)
        }
    }

    func testLongValuesExpandWithoutCappingOrMovingIcon() {
        let ordinary = SplitMenuBarRenderer.layout(readout: .init(upper: "42.0%", lower: "12.0%"))
        let long = SplitMenuBarRenderer.layout(readout: .init(upper: "123456789012345.6%", lower: "—"))
        XCTAssertGreaterThan(long.size.width, ordinary.size.width)
        XCTAssertEqual(long.size.height, 22)
        XCTAssertEqual(long.iconRect, ordinary.iconRect)
        XCTAssertTrue(long.upperRowRect.contains(long.upperInkBounds))
        XCTAssertTrue(long.lowerRowRect.contains(long.lowerInkBounds))
    }

    func testCompleteStringsShareTrailingEdge() {
        let layout = SplitMenuBarRenderer.layout(readout: .init(upper: "<100.0%", lower: "2.0%"))
        XCTAssertEqual(layout.upperTextOrigin.x + layout.upperTextWidth, layout.upperRowRect.maxX, accuracy: 0.001)
        XCTAssertEqual(layout.lowerTextOrigin.x + layout.lowerTextWidth, layout.lowerRowRect.maxX, accuracy: 0.001)
        XCTAssertGreaterThan(layout.lowerTextOrigin.x, layout.upperTextOrigin.x)
        XCTAssertEqual(layout.upperTextOrigin.y - layout.lowerTextOrigin.y, 11, accuracy: 0.001)
    }

    func testBothRowsRenderAtNativeScalesAcrossAppearances() throws {
        let readouts = [
            SplitMenuBarReadout(upper: "42.0%", lower: "12.0%"),
            SplitMenuBarReadout(upper: "<100.0%", lower: ">100.0%"),
            SplitMenuBarReadout(upper: "—", lower: "<0.1%"),
            SplitMenuBarReadout(upper: "123456789012345.6%", lower: "100.0%"),
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua,
                     .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            try withAppearance(appearance) {
                for scale in [1, 2] {
                    for readout in readouts {
                        let image = SplitMenuBarRenderer.image(icon: solidIcon(), readout: readout)
                        let layout = SplitMenuBarRenderer.layout(readout: readout)
                        XCTAssertEqual(image.size, layout.size)
                        XCTAssertFalse(image.isTemplate)
                        let bitmap = try bitmap(image, scale: scale)
                        let upper = try inkBounds(in: bitmap, region: layout.upperRowRect, scale: scale)
                        let lower = try inkBounds(in: bitmap, region: layout.lowerRowRect, scale: scale)
                        XCTAssertNotNil(upper, "Upper row: \(name), \(scale)x, \(readout)")
                        XCTAssertNotNil(lower, "Lower row: \(name), \(scale)x, \(readout)")
                        for (bounds, row) in [(upper, layout.upperRowRect), (lower, layout.lowerRowRect)] {
                            let bounds = try XCTUnwrap(bounds)
                            XCTAssertGreaterThanOrEqual(bounds.minY, row.minY)
                            XCTAssertLessThanOrEqual(bounds.maxY, row.maxY)
                            XCTAssertGreaterThanOrEqual(bounds.minX, row.minX)
                            XCTAssertLessThanOrEqual(bounds.maxX, row.maxX)
                        }
                        XCTAssertGreaterThan(try XCTUnwrap(lower).minY, 0)
                        XCTAssertLessThan(try XCTUnwrap(upper).maxY, image.size.height)
                        XCTAssertGreaterThanOrEqual(try XCTUnwrap(upper).minY - XCTUnwrap(lower).maxY, 1)
                        let gap = NSRect(x: 18, y: 0, width: 4, height: 22)
                        XCTAssertNil(try inkBounds(in: bitmap, region: gap, scale: scale))
                        XCTAssertNotNil(try inkBounds(in: bitmap, region: layout.iconRect, scale: scale))
                    }
                }
            }
        }
    }

    func testTextUsesDrawingAppearanceInsteadOfCapturedColor() throws {
        let readout = SplitMenuBarReadout(upper: "42.0%", lower: "12.0%")
        let image = SplitMenuBarRenderer.image(icon: solidIcon(), readout: readout)
        let textRegion = SplitMenuBarRenderer.layout(readout: readout).upperRowRect
        var brightness: [CGFloat] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            try withAppearance(appearance) {
                let bitmap = try bitmap(image, scale: 2)
                var total: CGFloat = 0
                var count: CGFloat = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let point = NSPoint(x: (CGFloat(x) + 0.5) / 2,
                                            y: (CGFloat(bitmap.pixelsHigh - y) - 0.5) / 2)
                        guard textRegion.contains(point),
                              let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              color.alphaComponent > 0.8 else { continue }
                        total += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        count += 1
                    }
                }
                XCTAssertGreaterThan(count, 0)
                brightness.append(total / max(count, 1))
            }
        }
        XCTAssertGreaterThan(brightness[1] - brightness[0], 0.5)
    }

    func testLongDarkTextMatchesUnclippedPaddedReference() throws {
        let readout = SplitMenuBarReadout(upper: "123456789012345.6%", lower: "100.0%")
        let layout = SplitMenuBarRenderer.layout(readout: readout)
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        try withAppearance(appearance) {
            for scale in [1, 2] {
                let emptyIcon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in true }
                let actual = try bitmap(SplitMenuBarRenderer.image(icon: emptyIcon, readout: readout), scale: scale)
                let padding: CGFloat = 4
                let referenceImage = NSImage(size: NSSize(width: layout.size.width + padding * 2,
                                                         height: layout.size.height + padding * 2), flipped: false) { _ in
                    guard let context = NSGraphicsContext.current?.cgContext else { return false }
                    context.textMatrix = .identity
                    for (text, origin) in [(readout.upper, layout.upperTextOrigin), (readout.lower, layout.lowerTextOrigin)] {
                        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.labelColor.cgColor,
                        ]))
                        context.textPosition = NSPoint(x: origin.x + padding, y: origin.y + padding)
                        CTLineDraw(line, context)
                    }
                    return true
                }
                let reference = try bitmap(referenceImage, scale: scale)
                let referenceBounds = try XCTUnwrap(inkBounds(in: reference,
                    region: NSRect(origin: .zero, size: referenceImage.size), scale: scale))
                    .offsetBy(dx: -padding, dy: -padding)
                let actualBounds = try XCTUnwrap(inkBounds(in: actual,
                    region: NSRect(origin: .zero, size: layout.size), scale: scale))
                XCTAssertGreaterThan(referenceBounds.minX, layout.iconRect.maxX)
                XCTAssertLessThan(referenceBounds.maxX, layout.size.width)
                XCTAssertGreaterThan(referenceBounds.minY, 0)
                XCTAssertLessThan(referenceBounds.maxY, layout.size.height)
                XCTAssertEqual(actualBounds, referenceBounds)
                let upper = try XCTUnwrap(inkBounds(in: actual, region: layout.upperRowRect, scale: scale))
                let lower = try XCTUnwrap(inkBounds(in: actual, region: layout.lowerRowRect, scale: scale))
                let gap = NSRect(x: 22, y: lower.maxY, width: layout.size.width - 22,
                                 height: upper.minY - lower.maxY)
                XCTAssertGreaterThanOrEqual(gap.height, 1)
                XCTAssertNil(try inkBounds(in: actual, region: gap, scale: scale))
                print("Split menu bar \(scale)x dark: upper ink \(upper), lower ink \(lower), empty gap \(gap.height) pt; padded reference bounds match")
            }
        }
    }

    private func solidIcon() -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
    }

    private func bitmap(_ image: NSImage, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale,
            pixelsHigh: Int(image.size.height) * scale, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return bitmap
    }

    private func inkBounds(in bitmap: NSBitmapImageRep, region: NSRect, scale: Int) throws -> NSRect? {
        let scale = CGFloat(scale)
        var bounds: NSRect?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let pixel = NSRect(x: CGFloat(x) / scale,
                                   y: CGFloat(bitmap.pixelsHigh - y - 1) / scale,
                                   width: 1 / scale, height: 1 / scale)
                guard region.contains(NSPoint(x: pixel.midX, y: pixel.midY)),
                      let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                bounds = bounds.map { $0.union(pixel) } ?? pixel
            }
        }
        return bounds
    }

    private func withAppearance(_ appearance: NSAppearance, _ body: () throws -> Void) throws {
        var failure: Error?
        appearance.performAsCurrentDrawingAppearance {
            do { try body() } catch { failure = error }
        }
        if let failure { throw failure }
    }
}
