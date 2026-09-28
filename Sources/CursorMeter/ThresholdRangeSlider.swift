import AppKit

/// Dual-thumb range slider for the Warning/Critical notification thresholds
/// (#81). AppKit has no native range slider, so this custom view owns the
/// track drawing, two thumbs, value bubbles, mouse/keyboard input, and
/// per-thumb accessibility. All geometry/constraint math lives in pure
/// static funcs so it is testable without a window.
final class ThresholdRangeSlider: NSView {

    enum Thumb { case warning, critical }

    static let step = 5
    static let minGap = 5

    private(set) var warningValue = 80
    private(set) var criticalValue = 90

    /// Fires live during drag / keyboard nudge. Never fired by `setValues`.
    var onChange: ((_ warning: Int, _ critical: Int) -> Void)?

    /// Programmatic update (updateUI path). Normalizes both values so any
    /// corrupted persisted pair lands inside 0...100 with the minimum gap:
    /// W first (so C can always fit above it), then C.
    func setValues(warning: Int, critical: Int) {
        warningValue = min(max(warning, 0), 100 - Self.minGap)
        criticalValue = min(max(critical, warningValue + Self.minGap), 100)
        valuesDidChange()
    }

    // MARK: - Layout metrics (76pt total: bubbles / track+thumbs / ticks / legend)

    private static let trackHeight: CGFloat = 5
    private static let thumbSize = NSSize(width: 14, height: 24)
    private static let trackInsetX: CGFloat = 7   // half thumb width, keeps pills inside bounds
    private static let bubbleRowY: CGFloat = 0
    private static let trackY: CGFloat = 22
    private static let ticksY: CGFloat = 40
    private static let legendY: CGFloat = 58

    private var activeThumb: Thumb?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 76) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var trackRect: NSRect {
        NSRect(x: Self.trackInsetX,
               y: Self.trackY,
               width: max(bounds.width - Self.trackInsetX * 2, 0),
               height: Self.trackHeight)
    }

    private func thumbCenterX(_ value: Int) -> CGFloat {
        let t = trackRect
        return t.minX + t.width * CGFloat(value) / 100
    }

    private func thumbRect(_ value: Int) -> NSRect {
        NSRect(x: thumbCenterX(value) - Self.thumbSize.width / 2,
               y: trackRect.midY - Self.thumbSize.height / 2,
               width: Self.thumbSize.width,
               height: Self.thumbSize.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawTrackAndZones()
        drawThumb(at: warningValue, color: CircularProgressIcon.warnColor)
        drawThumb(at: criticalValue, color: CircularProgressIcon.critColor)
        drawBubbles()
        drawTicks()
        drawLegend()
    }

    private func drawTrackAndZones() {
        let t = trackRect
        guard t.width > 0 else { return }
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: t, xRadius: 2.5, yRadius: 2.5).fill()

        let wx = thumbCenterX(warningValue)
        let cx = thumbCenterX(criticalValue)
        // Clip zone fills to the rounded track — restore state so the rest
        // of draw() (thumbs, bubbles, ticks, legend) is not clipped with it.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: t, xRadius: 2.5, yRadius: 2.5).setClip()
        func fill(_ from: CGFloat, _ to: CGFloat, _ color: NSColor) {
            color.setFill()
            NSRect(x: from, y: t.minY, width: max(to - from, 0), height: t.height).fill()
        }
        fill(t.minX, wx, CircularProgressIcon.accentColor.withAlphaComponent(0.4))
        fill(wx, cx, CircularProgressIcon.warnColor.withAlphaComponent(0.45))
        fill(cx, t.maxX, CircularProgressIcon.critColor.withAlphaComponent(0.45))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawThumb(at value: Int, color: NSColor) {
        let rect = thumbRect(value)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.thumbSize.width / 2, yRadius: Self.thumbSize.width / 2)
        color.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.stroke()
    }

    private func drawBubbles() {
        // When the chips would overlap horizontally, the critical chip drops
        // below the track (mockup near-state behavior).
        let w = bubble(text: "W \(warningValue)%",
                       background: CircularProgressIcon.warnColor,
                       textColor: NSColor.black.withAlphaComponent(0.85))
        let c = bubble(text: "C \(criticalValue)%",
                       background: CircularProgressIcon.critColor,
                       textColor: .white)
        let wOrigin = NSPoint(x: clampX(thumbCenterX(warningValue) - w.size.width / 2, width: w.size.width),
                              y: Self.bubbleRowY)
        var cOrigin = NSPoint(x: clampX(thumbCenterX(criticalValue) - c.size.width / 2, width: c.size.width),
                              y: Self.bubbleRowY)
        if wOrigin.x + w.size.width + 4 > cOrigin.x {
            cOrigin.y = thumbRect(criticalValue).maxY + 2
        }
        drawChip(w, at: wOrigin)
        drawChip(c, at: cOrigin)
    }

    private struct Chip {
        let text: NSAttributedString
        let size: NSSize
    }

    private func bubble(text: String, background: NSColor, textColor: NSColor) -> Chip {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: textColor,
            .backgroundColor: NSColor.clear,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        var size = str.size()
        size.width += 10; size.height += 3
        return Chip(text: str, size: size)
    }

    private func drawChip(_ chip: Chip, at origin: NSPoint) {
        let rect = NSRect(origin: origin, size: chip.size)
        let bg: NSColor = chip.text.string.hasPrefix("W")
            ? CircularProgressIcon.warnColor : CircularProgressIcon.critColor
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        chip.text.draw(at: NSPoint(x: origin.x + 5, y: origin.y + 1.5))
    }

    private func clampX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, 0), max(bounds.width - width, 0))
    }

    private func drawTicks() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for value in stride(from: 0, through: 100, by: 25) {
            let str = NSAttributedString(string: "\(value)", attributes: attrs)
            let x = clampX(thumbCenterX(value) - str.size().width / 2, width: str.size().width)
            str.draw(at: NSPoint(x: x, y: Self.ticksY))
        }
    }

    private func drawLegend() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var x: CGFloat = Self.trackInsetX
        let items: [(String, NSColor)] = [
            ("Normal", CircularProgressIcon.accentColor),
            ("Warning", CircularProgressIcon.warnColor),
            ("Critical", CircularProgressIcon.critColor),
        ]
        for (label, color) in items {
            let swatch = NSRect(x: x, y: Self.legendY + 2, width: 8, height: 8)
            color.setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
            let str = NSAttributedString(string: label, attributes: attrs)
            str.draw(at: NSPoint(x: x + 12, y: Self.legendY))
            x += 12 + str.size().width + 12
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)   // route subsequent arrow keys here
        let x = convert(event.locationInWindow, from: nil).x
        let p = Self.snappedPercent(forX: x, trackMinX: trackRect.minX, trackWidth: trackRect.width)
        activeThumb = Self.nearestThumb(toPercent: p, warning: warningValue, critical: criticalValue)
        applyDrag(toPercent: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        applyDrag(toPercent: Self.snappedPercent(forX: x, trackMinX: trackRect.minX, trackWidth: trackRect.width))
    }

    override func mouseUp(with event: NSEvent) {
        activeThumb = nil
    }

    private func applyDrag(toPercent p: Int) {
        guard let thumb = activeThumb else { return }
        let r = Self.resolve(dragging: thumb, toRaw: p, warning: warningValue, critical: criticalValue)
        guard r.warning != warningValue || r.critical != criticalValue else { return }
        warningValue = r.warning
        criticalValue = r.critical
        valuesDidChange()
        onChange?(warningValue, criticalValue)
    }

    private func valuesDidChange() {
        needsDisplay = true
        syncAccessibilityFrames()
        NSAccessibility.post(element: axWarning, notification: .valueChanged)
        NSAccessibility.post(element: axCritical, notification: .valueChanged)
    }

    // MARK: - Keyboard (←/→ = warning thumb, ⇧←/⇧→ = critical thumb)

    override func keyDown(with event: NSEvent) {
        let delta: Int
        switch event.specialKey {
        case .leftArrow:  delta = -Self.step
        case .rightArrow: delta = Self.step
        default:
            super.keyDown(with: event)
            return
        }
        nudge(event.modifierFlags.contains(.shift) ? .critical : .warning, by: delta)
    }

    /// Returns true when the value actually changed (false at a boundary).
    @discardableResult
    private func nudge(_ thumb: Thumb, by delta: Int) -> Bool {
        let previous = activeThumb
        defer { activeThumb = previous }
        activeThumb = thumb
        let before = (warningValue, criticalValue)
        let raw = (thumb == .warning ? warningValue : criticalValue) + delta
        applyDrag(toPercent: raw)
        return (warningValue, criticalValue) != before
    }

    // MARK: - Accessibility (one virtual slider element per thumb)

    private lazy var axWarning = makeAXThumb(.warning, label: "Warning threshold")
    private lazy var axCritical = makeAXThumb(.critical, label: "Critical threshold")

    func setAccessibilityScope(_ scope: String) {
        axWarning.setAccessibilityLabel("\(scope) warning threshold")
        axCritical.setAccessibilityLabel("\(scope) critical threshold")
    }

    private func makeAXThumb(_ thumb: Thumb, label: String) -> ThumbAXElement {
        let element = ThumbAXElement()
        element.thumb = thumb
        element.owner = self
        element.setAccessibilityRole(.slider)
        element.setAccessibilityLabel(label)
        element.setAccessibilityParent(self)
        return element
    }

    override func layout() {
        super.layout()
        syncAccessibilityFrames()
    }

    private func syncAccessibilityFrames() {
        axWarning.setAccessibilityFrameInParentSpace(thumbRect(warningValue))
        axCritical.setAccessibilityFrameInParentSpace(thumbRect(criticalValue))
    }

    override func accessibilityChildren() -> [Any]? { [axWarning, axCritical] }
    override func isAccessibilityElement() -> Bool { false }

    fileprivate func axValue(for thumb: Thumb) -> Int {
        thumb == .warning ? warningValue : criticalValue
    }

    fileprivate func axNudge(_ thumb: Thumb, by delta: Int) -> Bool {
        nudge(thumb, by: delta)
    }

    // MARK: - Pure geometry/constraint logic

    static func snappedPercent(forX x: CGFloat, trackMinX: CGFloat, trackWidth: CGFloat) -> Int {
        guard trackWidth > 0 else { return 0 }
        let fraction = (x - trackMinX) / trackWidth
        let raw = fraction * 100
        let snapped = Int((raw / CGFloat(step)).rounded()) * step
        return min(max(snapped, 0), 100)
    }

    static func resolve(dragging thumb: Thumb, toRaw raw: Int, warning: Int, critical: Int) -> (warning: Int, critical: Int) {
        switch thumb {
        case .warning:
            return (min(max(raw, 0), critical - minGap), critical)
        case .critical:
            return (warning, min(max(raw, warning + minGap), 100))
        }
    }

    static func nearestThumb(toPercent p: Int, warning: Int, critical: Int) -> Thumb {
        abs(p - warning) <= abs(p - critical) ? .warning : .critical
    }
}

/// Virtual accessibility element for one thumb. AX callbacks are nonisolated
/// but always arrive on the main thread — `assumeIsolated` bridges to the
/// MainActor-isolated owner.
private final class ThumbAXElement: NSAccessibilityElement {
    weak var owner: ThresholdRangeSlider?
    var thumb: ThresholdRangeSlider.Thumb = .warning

    // Numeric value + percent valueDescription — matches native NSSlider's
    // AX typing (numeric value, human string separate).
    override func accessibilityValue() -> Any? {
        let owner = self.owner, thumb = self.thumb
        let value: Int? = MainActor.assumeIsolated { owner?.axValue(for: thumb) }
        return value
    }

    override func accessibilityValueDescription() -> String? {
        let owner = self.owner, thumb = self.thumb
        return MainActor.assumeIsolated { owner.map { "\($0.axValue(for: thumb))%" } }
    }

    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { 100 }

    override func accessibilityPerformIncrement() -> Bool {
        let owner = self.owner, thumb = self.thumb
        return MainActor.assumeIsolated { owner?.axNudge(thumb, by: ThresholdRangeSlider.step) ?? false }
    }

    override func accessibilityPerformDecrement() -> Bool {
        let owner = self.owner, thumb = self.thumb
        return MainActor.assumeIsolated { owner?.axNudge(thumb, by: -ThresholdRangeSlider.step) ?? false }
    }
}
