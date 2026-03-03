import AppKit

// MARK: - Progress Level

enum ProgressLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    var color: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        }
    }
}

// MARK: - Circular Progress Icon

enum CircularProgressIcon {
    static func level(for percent: Double) -> ProgressLevel {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }

    /// Pie chart icon only
    static func menuBarImage(percent: Double, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawPie(in: ctx, rect: rect, percent: percent)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Pie chart + fraction text (used / limit) as a single NSImage
    static func menuBarImageWithText(percent: Double, used: Int, limit: Int) -> NSImage {
        let pieSize: CGFloat = 20
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let textColor = NSColor.labelColor

        let usedStr = NSAttributedString(string: "\(used)", attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let limitStr = NSAttributedString(string: "\(limit)", attributes: [
            .font: font, .foregroundColor: textColor,
        ])

        let usedSize = usedStr.size()
        let limitSize = limitStr.size()
        let textWidth = max(usedSize.width, limitSize.width)
        let lineHeight: CGFloat = 1
        let textBlockHeight = usedSize.height + lineHeight + limitSize.height
        let gap: CGFloat = 3

        let totalWidth = pieSize + gap + textWidth + 1
        let totalHeight: CGFloat = 22

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw pie (vertically centered)
            let pieY = (totalHeight - pieSize) / 2
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pieY)
            let pieRect = CGRect(x: 0, y: 0, width: pieSize, height: pieSize)
            drawPie(in: ctx, rect: pieRect, percent: percent)
            ctx.restoreGState()

            // Draw fraction text (vertically centered)
            let textX = pieSize + gap
            let textY = (totalHeight - textBlockHeight) / 2

            // Limit (bottom)
            limitStr.draw(at: NSPoint(
                x: textX + (textWidth - limitSize.width) / 2,
                y: textY
            ))

            // Divider line
            let lineY = textY + limitSize.height + lineHeight / 2
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: textX, y: lineY))
            ctx.addLine(to: CGPoint(x: textX + textWidth, y: lineY))
            ctx.strokePath()

            // Used (top)
            usedStr.draw(at: NSPoint(
                x: textX + (textWidth - usedSize.width) / 2,
                y: textY + limitSize.height + lineHeight
            ))

            return true
        }
        image.isTemplate = false
        return image
    }

    /// "Cursor Meter" text icon for idle/not-logged-in state
    static func idleImage() -> NSImage {
        let topFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let bottomFont = NSFont.systemFont(ofSize: 6, weight: .regular)
        let color = NSColor.labelColor

        let topStr = NSAttributedString(string: "Cursor", attributes: [
            .font: topFont, .foregroundColor: color,
        ])
        let bottomStr = NSAttributedString(string: "Meter", attributes: [
            .font: bottomFont, .foregroundColor: color,
        ])

        let topSize = topStr.size()
        let bottomSize = bottomStr.size()
        let width = max(topSize.width, bottomSize.width) + 2
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let totalText = topSize.height + bottomSize.height
            let startY = (height - totalText) / 2

            bottomStr.draw(at: NSPoint(
                x: (width - bottomSize.width) / 2,
                y: startY
            ))
            topStr.draw(at: NSPoint(
                x: (width - topSize.width) / 2,
                y: startY + bottomSize.height
            ))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Private

    private static func pieColor(for percent: Double) -> NSColor {
        if percent >= 90 { return NSColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1) }
        if percent >= 70 { return NSColor(red: 0.95, green: 0.65, blue: 0.0, alpha: 1) }
        return NSColor(red: 0.20, green: 0.70, blue: 0.25, alpha: 1)
    }

    private static func drawPie(in ctx: CGContext, rect: CGRect, percent: Double) {
        let inset: CGFloat = 1
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) - inset * 2) / 2

        // Track (adapts to system appearance)
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.2).cgColor)
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2)
        ctx.addEllipse(in: circleRect)
        ctx.fillPath()

        // Border
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(0.75)
        ctx.addEllipse(in: circleRect)
        ctx.strokePath()

        // Pie wedge
        let progress = min(max(percent / 100.0, 0), 1.0)
        if progress > 0 {
            let nsColor = pieColor(for: percent)
            ctx.setFillColor(nsColor.cgColor)

            let startAngle = CGFloat.pi / 2
            let endAngle = startAngle - (2 * .pi * progress)

            ctx.move(to: center)
            ctx.addArc(center: center, radius: radius,
                       startAngle: startAngle, endAngle: endAngle, clockwise: true)
            ctx.closePath()
            ctx.fillPath()
        }
    }
}
