import AppKit

/// 7-day usage bar graph rendered with Core Graphics (no layer-backing) inside
/// the popover. Reuses `CircularProgressIcon`'s color tokens so heat color
/// stays consistent with the menu-bar ring.
@MainActor
final class WeeklyUsageChartView: NSView {
    private var days: [DayUsage] = []
    private var style: WeeklyChartStyle = .outline
    private var metric: WeeklyChartMetric = .amount
    private var hoverIndex: Int?
    private var trackingArea: NSTrackingArea?

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE"
        return f
    }()

    nonisolated static func tooltipText(for day: DayUsage, metric: WeeklyChartMetric) -> String {
        guard let value = metric.value(for: day) else { return "Amount unavailable" }
        switch metric {
        case .amount:
            return String(format: "$%.2f", value / 100)
        case .usageUnits:
            if value > 0, value < 0.01 { return "<0.01 units" }
            let number = String(format: "%.2f", value)
                .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            return "\(number) units"
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // wantsLayer left as default (false) — avoids the ~90KB backing-store
        // hit on a 280×80 view. Drawing is pure CG into the window backing.
    }

    required init?(coder: NSCoder) { nil }

    func update(days: [DayUsage], style: WeeklyChartStyle, metric: WeeklyChartMetric) {
        self.days = days
        self.style = style
        self.metric = days.effectiveMetric(preferred: metric)
        self.hoverIndex = nil
        needsDisplay = true
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let next = barIndex(at: p)
        if next != hoverIndex {
            hoverIndex = next
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil {
            hoverIndex = nil
            needsDisplay = true
        }
    }

    // MARK: - Layout

    private var chartInsets: NSEdgeInsets {
        NSEdgeInsets(top: 6, left: 6, bottom: 16, right: 6)
    }

    private var chartRect: NSRect {
        NSRect(
            x: bounds.minX + chartInsets.left,
            y: bounds.minY + chartInsets.bottom,
            width: max(0, bounds.width - chartInsets.left - chartInsets.right),
            height: max(0, bounds.height - chartInsets.top - chartInsets.bottom)
        )
    }

    private let barGap: CGFloat = 6

    private func barWidth(in chart: NSRect, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return (chart.width - barGap * CGFloat(count - 1)) / CGFloat(count)
    }

    private func barFrame(index: Int, height: CGFloat) -> NSRect {
        let chart = chartRect
        let bw = barWidth(in: chart, count: days.count)
        let x = chart.minX + (bw + barGap) * CGFloat(index)
        return NSRect(x: x, y: chart.minY, width: bw, height: height)
    }

    private func barIndex(at point: NSPoint) -> Int? {
        guard days.count == 7 else { return nil }
        let chart = chartRect
        let bw = barWidth(in: chart, count: days.count)
        guard bw > 0, point.x >= chart.minX, point.x <= chart.maxX else { return nil }
        // Tolerate vertical hovering anywhere within the view (including the label strip).
        let idx = Int((point.x - chart.minX) / (bw + barGap))
        return (0..<days.count).contains(idx) ? idx : nil
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard days.count == 7 else { return }

        let chart = chartRect
        let weeklyMax = days.compactMap { metric.value(for: $0) }.max() ?? 0
        let yMaxRaw = weeklyMax * 1.05
        let yMax: Double = yMaxRaw > 0 ? yMaxRaw : 1

        drawBars(in: ctx, chart: chart, weeklyMax: weeklyMax, yMax: yMax)
        drawHoverTooltip(in: ctx, chart: chart, yMax: yMax)
    }

    private func drawBars(in ctx: CGContext, chart: NSRect, weeklyMax: Double, yMax: Double) {
        for (i, day) in days.enumerated() {
            let value = metric.value(for: day) ?? 0
            let normalized = value / yMax
            let h = max(CGFloat(normalized) * chart.height, 0)

            let dimmed = (style == .dimOthers || style == .both) && !day.isToday
            let alpha: CGFloat = dimmed ? 0.35 : 1.0

            if value == 0 {
                // Bottom-aligned placeholder dot keeps every day's baseline aligned.
                let rect = barFrame(index: i, height: 1.5)
                CircularProgressIcon.accentColor.withAlphaComponent(0.45 * alpha).setFill()
                NSBezierPath(rect: rect).fill()
            } else {
                let color = heatColor(value: value, weeklyMax: weeklyMax)
                let rect = barFrame(index: i, height: h)
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
                color.withAlphaComponent(alpha).setFill()
                path.fill()

                if day.isToday, style == .outline || style == .both {
                    NSColor.white.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }

            drawWeekdayLabel(day: day, chart: chart, index: i)
        }
    }

    private func heatColor(value: Double, weeklyMax: Double) -> NSColor {
        guard weeklyMax > 0 else { return CircularProgressIcon.accentColor }
        let pct = value / weeklyMax * 100
        if pct >= 85 { return CircularProgressIcon.critColor }
        if pct >= 60 { return CircularProgressIcon.warnColor }
        return CircularProgressIcon.accentColor
    }

    private func drawWeekdayLabel(day: DayUsage, chart: NSRect, index: Int) {
        let label = Self.weekdayFormatter.string(from: day.date)
        let font = NSFont.systemFont(ofSize: 9, weight: day.isToday ? .semibold : .regular)
        let color: NSColor = day.isToday ? .labelColor : .secondaryLabelColor
        let attr = NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: color,
        ])
        let size = attr.size()
        let frame = barFrame(index: index, height: 0)
        let x = frame.midX - size.width / 2
        let y = chart.minY - size.height - 2
        attr.draw(at: NSPoint(x: x, y: y))
    }

    private func drawHoverTooltip(in ctx: CGContext, chart: NSRect, yMax: Double) {
        guard let idx = hoverIndex else { return }
        let day = days[idx]
        let text = NSAttributedString(string: Self.tooltipText(for: day, metric: metric), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        let padX: CGFloat = 5
        let padY: CGFloat = 3
        let boxW = textSize.width + padX * 2
        let boxH = textSize.height + padY * 2

        let normalized = (metric.value(for: day) ?? 0) / yMax
        let barH = max(CGFloat(normalized) * chart.height, 1.5)
        let frame = barFrame(index: idx, height: barH)

        var box = NSRect(
            x: frame.midX - boxW / 2,
            y: frame.maxY + 4,
            width: boxW,
            height: boxH
        )
        if box.maxX > bounds.maxX { box.origin.x = bounds.maxX - box.width }
        if box.minX < bounds.minX { box.origin.x = bounds.minX }
        if box.maxY > bounds.maxY { box.origin.y = frame.maxY - box.height - 4 }

        ctx.setFillColor(NSColor(white: 0, alpha: 0.78).cgColor)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        path.fill()

        text.draw(at: NSPoint(
            x: box.midX - textSize.width / 2,
            y: box.midY - textSize.height / 2
        ))
    }
}
