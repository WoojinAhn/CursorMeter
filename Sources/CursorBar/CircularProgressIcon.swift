import SwiftUI
import AppKit

// MARK: - Progress Level

enum ProgressLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
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

    static func menuBarImage(percent: Double, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let lineWidth: CGFloat = 1.5
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = (min(rect.width, rect.height) - lineWidth * 2) / 2

            // Track
            ctx.setStrokeColor(NSColor.gray.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
            ctx.strokePath()

            // Progress arc
            let progress = min(max(percent / 100.0, 0), 1.0)
            if progress > 0 {
                let nsColor = NSColor(level(for: percent).color)
                ctx.setStrokeColor(nsColor.cgColor)
                ctx.setLineWidth(lineWidth)
                ctx.setLineCap(.round)

                // Start at 12 o'clock, go clockwise
                let startAngle = CGFloat.pi / 2
                let endAngle = startAngle - (2 * .pi * progress)
                ctx.addArc(center: center, radius: radius,
                           startAngle: startAngle, endAngle: endAngle, clockwise: true)
                ctx.strokePath()
            }

            return true
        }
        image.isTemplate = false
        return image
    }
}
