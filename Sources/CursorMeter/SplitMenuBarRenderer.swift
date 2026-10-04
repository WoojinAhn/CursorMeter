import AppKit
import CoreText

enum SplitMenuBarRenderer {
    struct Layout: Sendable {
        let size: NSSize
        let iconRect: NSRect
        let upperRowRect: NSRect
        let lowerRowRect: NSRect
        let upperTextOrigin: NSPoint
        let lowerTextOrigin: NSPoint
        let upperTextWidth: CGFloat
        let lowerTextWidth: CGFloat
        let upperInkBounds: NSRect
        let lowerInkBounds: NSRect
    }

    private static let baselineStrings = ["0.0%", "99.9%", "100.0%", "<0.1%", "<100.0%", ">100.0%", "—"]
    // NSImage drawing handlers may run off-main; keep non-Sendable font state local.
    private static var font: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .medium) }

    static func layout(readout: SplitMenuBarReadout) -> Layout {
        let baselineLines = baselineStrings.map { line($0) }
        let upper = line(readout.upper)
        let lower = line(readout.lower)
        let upperWidth = CGFloat(CTLineGetTypographicBounds(upper, nil, nil, nil))
        let lowerWidth = CGFloat(CTLineGetTypographicBounds(lower, nil, nil, nil))
        let reservedWidth = CGFloat(CTLineGetTypographicBounds(line("99.9%"), nil, nil, nil))
        let textWidth = ceil(max(reservedWidth, upperWidth, lowerWidth))
        let upperRow = NSRect(x: 22, y: 11, width: textWidth, height: 11)
        let lowerRow = NSRect(x: 22, y: 0, width: textWidth, height: 11)
        // AppKit's 13 pt line height exceeds each row; center glyph ink on a shared baseline instead.
        let referenceInk = baselineLines.map { CTLineGetBoundsWithOptions($0, .useGlyphPathBounds) }
            .reduce(CGRect.null) { $0.union($1) }
        let upperOrigin = NSPoint(x: upperRow.maxX - upperWidth, y: upperRow.midY - referenceInk.midY)
        let lowerOrigin = NSPoint(x: lowerRow.maxX - lowerWidth, y: lowerRow.midY - referenceInk.midY)
        return Layout(
            size: NSSize(width: upperRow.maxX, height: 22),
            iconRect: NSRect(x: 0, y: 2, width: 18, height: 18),
            upperRowRect: upperRow, lowerRowRect: lowerRow,
            upperTextOrigin: upperOrigin, lowerTextOrigin: lowerOrigin,
            upperTextWidth: upperWidth, lowerTextWidth: lowerWidth,
            upperInkBounds: CTLineGetBoundsWithOptions(upper, .useGlyphPathBounds)
                .offsetBy(dx: upperOrigin.x, dy: upperOrigin.y),
            lowerInkBounds: CTLineGetBoundsWithOptions(lower, .useGlyphPathBounds)
                .offsetBy(dx: lowerOrigin.x, dy: lowerOrigin.y))
    }

    static func image(icon: NSImage, readout: SplitMenuBarReadout) -> NSImage {
        let layout = layout(readout: readout)
        let image = NSImage(size: layout.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            icon.draw(in: layout.iconRect)
            context.saveGState()
            defer { context.restoreGState() }
            context.textMatrix = .identity
            context.textPosition = layout.upperTextOrigin
            CTLineDraw(line(readout.upper, color: .labelColor), context)
            context.textPosition = layout.lowerTextOrigin
            CTLineDraw(line(readout.lower, color: .labelColor), context)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func line(_ text: String, color: NSColor = .labelColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]))
    }
}
