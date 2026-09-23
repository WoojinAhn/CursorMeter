import AppKit
import QuartzCore

@MainActor
final class RefreshFeedbackButton: NSButton {
    enum Style { case iconOnly, labeled }
    enum Consumer { case meter, recent }

    private let displayStyle: Style
    private let consumer: Consumer
    private let glyph = NSTextField(labelWithString: "↻")
    private let caption = NSTextField(labelWithString: "Refresh")
    private var displayedPhase: RefreshPhase = .idle
    private var displayedAttempt: RefreshAttempt?
    private var displayedReduceMotion = false
    private var hasRendered = false

    init(style: Style, consumer: Consumer) {
        displayStyle = style
        self.consumer = consumer
        super.init(frame: .zero)
        title = ""
        bezelStyle = .rounded
        isBordered = style == .labeled
        focusRingType = .default
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(consumer == .meter ? "Refresh usage" : "Refresh recent usage")
        setAccessibilityRole(.button)

        glyph.font = .systemFont(ofSize: 16, weight: .medium)
        glyph.alignment = .center
        glyph.textColor = .secondaryLabelColor
        glyph.wantsLayer = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .labelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.isHidden = style == .iconOnly
        addSubview(caption)
        let width: CGFloat = style == .iconOnly ? 26 : 90
        let height: CGFloat = style == .iconOnly ? 24 : 26
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 20),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style == .iconOnly ? 4 : 10),
        ])
        if style == .labeled {
            NSLayoutConstraint.activate([
                caption.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
                caption.centerYAnchor.constraint(equalTo: centerYAnchor),
                caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(style:consumer:)") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        centerGlyphLayer()
    }

    private func centerGlyphLayer() {
        guard let layer = glyph.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: glyph.frame.midX, y: glyph.frame.midY)
    }

    func render(phase: RefreshPhase, isReady: Bool, attempt: RefreshAttempt?,
                isAuthenticated: Bool, reduceMotion: Bool) {
        let changed = !hasRendered || phase != displayedPhase || attempt != displayedAttempt
            || reduceMotion != displayedReduceMotion
        isEnabled = isAuthenticated && isReady
        guard changed else { return }
        hasRendered = true
        displayedPhase = phase
        displayedAttempt = attempt
        displayedReduceMotion = reduceMotion

        let state: String
        switch phase {
        case .idle:
            glyph.stringValue = "↻"
            state = "Refresh"
        case .updating:
            glyph.stringValue = "↻"
            state = "Updating"
        case let .result(meter, recent):
            let outcome = consumer == .meter ? meter : recent
            glyph.stringValue = outcome == .success ? "✓" : "⚠"
            state = outcome == .success ? "Updated" : "Retry later"
        }
        caption.stringValue = state
        setAccessibilityValue(state)
        setAccessibilityHelp(state)

        if case .updating = phase, !reduceMotion {
            centerGlyphLayer()
            if glyph.layer?.animation(forKey: "refreshRotation") == nil {
                let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = 0
                animation.toValue = Double.pi * 2
                animation.duration = 0.9
                animation.repeatCount = .infinity
                let now = CACurrentMediaTime()
                animation.beginTime = now - now.truncatingRemainder(dividingBy: animation.duration)
                glyph.layer?.add(animation, forKey: "refreshRotation")
            }
        } else {
            glyph.layer?.removeAnimation(forKey: "refreshRotation")
        }
    }
}
