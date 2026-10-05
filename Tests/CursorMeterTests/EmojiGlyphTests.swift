import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class EmojiGlyphTests: XCTestCase {
    func testSizeMatchesRequest() {
        let img = CircularProgressIcon.makeEmojiImage(emoji: "⚡", size: NSSize(width: 22, height: 22))
        XCTAssertEqual(img.size.width, 22, accuracy: 0.5)
        XCTAssertEqual(img.size.height, 22, accuracy: 0.5)
    }

    func testNonEmptyRendering() throws {
        let img = CircularProgressIcon.makeEmojiImage(emoji: "🚀", size: NSSize(width: 22, height: 22))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = img.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.current = context
        context.cgContext.clear(NSRect(origin: .zero, size: img.size))
        img.draw(in: NSRect(origin: .zero, size: img.size))
        let hasVisiblePixels = (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
            }
        }
        XCTAssertTrue(hasVisiblePixels, "The emoji drawing must produce visible pixels")
    }

    func testGlowDoesNotChangeSize() {
        let plain = CircularProgressIcon.makeEmojiImage(emoji: "🚀", size: NSSize(width: 22, height: 22), glow: false)
        let glow = CircularProgressIcon.makeEmojiImage(emoji: "🚀", size: NSSize(width: 22, height: 22), glow: true)
        XCTAssertEqual(plain.size, glow.size)
    }
}
