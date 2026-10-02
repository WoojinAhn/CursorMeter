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
    /// Shared color tokens used by the menu-bar ring and the popover weekly chart.
    /// Reused across surfaces so heat color never drifts between views.
    static let accentColor = NSColor(red: 0.20, green: 0.70, blue: 0.25, alpha: 1)
    static let warnColor = NSColor(red: 0.95, green: 0.65, blue: 0.0, alpha: 1)
    static let critColor = NSColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1)

    static func level(for percent: Double) -> ProgressLevel {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }

    /// Maps a plan-percent (0–100+) to one of the shared color tokens.
    /// Single source of truth for both the menu-bar ring and the popover
    /// progress bar — prevents the bands from drifting (e.g. ring=green
    /// while progress bar=yellow at the same value).
    static func tokenColor(for percent: Double) -> NSColor {
        if percent >= 90 { return critColor }
        if percent >= 70 { return warnColor }
        return accentColor
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

    static func makeSplitImage(
        cursorPercent: Double?, otherPercent: Double?, outerPool: UsagePoolID = .other,
        size: NSSize = NSSize(width: 18, height: 18),
        todayPercentagePoints: [UsagePoolID: Double] = [:]
    ) -> NSImage {
        let outer = outerPool == .other ? otherPercent : cursorPercent
        let center = outerPool == .other ? cursorPercent : otherPercent
        let canShowToday = [cursorPercent, otherPercent].allSatisfy {
            guard let value = $0 else { return false }
            return value.isFinite && value >= 0 && value < 100
        }
        let outerToday = canShowToday ? todayPercentagePoints[outerPool] : nil
        let centerToday = canShowToday ? todayPercentagePoints[outerPool == .other ? .cursor : .other] : nil
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let diameter = min(rect.width, rect.height)
            let origin = CGPoint(x: rect.midX, y: rect.midY)
            let ringWidth = diameter / 9
            let ringRadius = diameter / 2 - ringWidth / 2 - diameter / 36
            let centerRadius = diameter * 0.27
            drawSplitRegion(in: context, center: origin, radius: ringRadius,
                            lineWidth: ringWidth, percent: outer, filled: false,
                            todayPercentagePoints: outerToday)
            drawSplitRegion(in: context, center: origin, radius: centerRadius,
                            lineWidth: diameter / 24, percent: center, filled: true,
                            todayPercentagePoints: centerToday)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Pie chart + fraction text (used / limit) as a single NSImage
    static func menuBarImageWithText(percent: Double, usedText: String, limitText: String) -> NSImage {
        let pieSize: CGFloat = 20
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let textColor = NSColor.labelColor

        let usedStr = NSAttributedString(string: usedText, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let limitStr = NSAttributedString(string: limitText, attributes: [
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

    /// Pie chart + percent text as a single NSImage
    static func menuBarImageWithPercent(percent: Double) -> NSImage {
        let pieSize: CGFloat = 20
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let textColor = NSColor.labelColor

        let percentStr = NSAttributedString(string: "\(Int(percent.rounded()))%", attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let textSize = percentStr.size()
        let gap: CGFloat = 3

        let totalWidth = pieSize + gap + textSize.width + 1
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

            // Draw percent text (vertically centered)
            let textX = pieSize + gap
            let textY = (totalHeight - textSize.height) / 2
            percentStr.draw(at: NSPoint(x: textX, y: textY))

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

    /// Idle logo + warning badge — shown when the stored session has expired
    /// and the user must log in again. Distinct from `idleImage()` so the
    /// expired state doesn't look identical to fresh-launch idle (#76,
    /// docs/mockup-issue-76-login-icon.html candidate C).
    ///
    /// Composites the existing `idleImage()` rather than redrawing the logo —
    /// the drawing handler re-runs at render time, so `labelColor` inside the
    /// nested image stays appearance-dynamic.
    static func loginRequiredImage() -> NSImage {
        let logo = idleImage()
        let badgeRadius: CGFloat = 4
        // Badge overhangs the logo's top-right corner; widen the canvas so it never clips.
        let size = NSSize(width: logo.size.width + badgeRadius, height: logo.size.height)

        let image = NSImage(size: size, flipped: false) { _ in
            logo.draw(
                at: .zero, from: .zero, operation: .sourceOver, fraction: 1)

            // Warning badge, top-right. Black "!" on warnColor reads in both
            // light and dark menu bars.
            let badgeCenter = NSPoint(x: size.width - badgeRadius, y: size.height - badgeRadius)
            let badgeRect = NSRect(
                x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                width: badgeRadius * 2, height: badgeRadius * 2)
            warnColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let bang = NSAttributedString(string: "!", attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .heavy),
                .foregroundColor: NSColor.black,
            ])
            let bangSize = bang.size()
            bang.draw(at: NSPoint(
                x: badgeCenter.x - bangSize.width / 2,
                y: badgeCenter.y - bangSize.height / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Renders an emoji glyph centered in a fixed-size NSImage suitable for
    /// `NSStatusItem.button.image` swap. Used for the usage-jump effect.
    ///
    /// The returned image's `size` matches the requested `size` exactly so that
    /// swapping it onto a pinned-length status item never shifts the slot.
    ///
    /// - Parameters:
    ///   - emoji: single Unicode scalar / sequence (e.g. `"⚡"`, `"🚀"`).
    ///   - size: target image size; should match the ring image size.
    ///   - glow: when `true`, attaches a red drop-shadow halo behind the glyph.
    static func makeEmojiImage(emoji: String, size: NSSize, glow: Bool = false) -> NSImage {
        // Font sized so a typical emoji glyph fills ~78% of the image height.
        let fontSize = size.height * 0.78
        let font = NSFont.systemFont(ofSize: fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]

        if glow {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = max(2, size.height * 0.18)
            shadow.shadowColor = NSColor.systemRed.withAlphaComponent(0.6)
            shadow.shadowOffset = .zero
            attrs[.shadow] = shadow
        }

        let attributed = NSAttributedString(string: emoji, attributes: attrs)
        let textSize = attributed.size()

        let image = NSImage(size: size, flipped: false) { rect in
            // Slight inset keeps any drop-shadow halo within image bounds.
            let inset: CGFloat = glow ? max(1, rect.height * 0.08) : 0
            let drawRect = rect.insetBy(dx: inset, dy: inset)

            // Center the glyph: NSAttributedString.draw uses the typographic
            // bounding box, so subtract the measured size from the available
            // box to obtain origin for visual centering.
            let originX = drawRect.minX + (drawRect.width - textSize.width) / 2
            let originY = drawRect.minY + (drawRect.height - textSize.height) / 2
            attributed.draw(at: NSPoint(x: originX, y: originY))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Private

    private static func pieColor(for percent: Double) -> NSColor {
        tokenColor(for: percent)
    }

    private static func drawSplitRegion(
        in context: CGContext, center: CGPoint, radius: CGFloat,
        lineWidth: CGFloat, percent: Double?, filled: Bool,
        todayPercentagePoints: Double? = nil
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        let bounds = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)
        guard let percent, percent.isFinite, percent >= 0 else {
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.65).cgColor)
            context.setLineDash(phase: 0, lengths: [lineWidth, lineWidth])
            context.strokeEllipse(in: bounds)
            if filled {
                context.setLineDash(phase: 0, lengths: [])
                context.move(to: CGPoint(x: center.x - radius * 0.4, y: center.y))
                context.addLine(to: CGPoint(x: center.x + radius * 0.4, y: center.y))
                context.strokePath()
            }
            return
        }
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.35).cgColor)
        context.strokeEllipse(in: bounds)
        if filled {
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.15).cgColor)
            context.fillEllipse(in: bounds)
        }
        let progress = min(percent, 100) / 100
        guard progress > 0 else { return }
        let color = tokenColor(for: percent).cgColor
        let start = CGFloat.pi / 2
        if filled {
            context.setFillColor(color)
            context.move(to: center)
        } else {
            context.setStrokeColor(color)
        }
        context.addArc(center: center, radius: radius, startAngle: start,
                       endAngle: start - 2 * .pi * progress, clockwise: true)
        if filled { context.closePath() }
        let originalPath = context.path
        if filled {
            context.fillPath()
        } else {
            context.strokePath()
        }
        guard let today = todayPercentagePoints, today.isFinite, today > 0, today <= percent,
              let originalPath else { return }
        let fillPath = filled ? originalPath : originalPath.copy(
            strokingWithWidth: lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        // Clipping keeps the official fill endpoint and the unused track authoritative.
        context.addPath(fillPath)
        context.clip()
        let todayColor = tokenColor(for: percent).blended(withFraction: 0.32, of: .white)
            ?? tokenColor(for: percent)
        let earlier = percent - today
        let boundary = start - 2 * .pi * earlier / 100
        if filled {
            context.setFillColor(todayColor.cgColor)
            context.move(to: center)
        } else {
            context.setStrokeColor(todayColor.cgColor)
        }
        context.addArc(center: center, radius: radius, startAngle: boundary,
                       endAngle: start - 2 * .pi * progress, clockwise: true)
        if filled {
            context.closePath()
            context.fillPath()
        } else {
            context.strokePath()
        }
        guard today >= 0.5, earlier >= 0.5 else { return }
        let innerRadius = filled ? 0 : radius - lineWidth / 2
        let outerRadius = filled ? radius : radius + lineWidth / 2
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(0.75)
        context.move(to: CGPoint(x: center.x + cos(boundary) * innerRadius,
                                y: center.y + sin(boundary) * innerRadius))
        context.addLine(to: CGPoint(x: center.x + cos(boundary) * outerRadius,
                                   y: center.y + sin(boundary) * outerRadius))
        context.strokePath()
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
