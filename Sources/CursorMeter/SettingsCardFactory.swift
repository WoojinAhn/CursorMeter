import AppKit

// MARK: - SettingsCardFactory

/// Layout-only helpers for the settings card-row visual language (#99).
/// Controls and their target/action wiring stay in the tab view controllers.
@MainActor
enum SettingsCardFactory {

    static let contentWidth: CGFloat = 440

    // MARK: Section

    /// Section header rendered outside a card (sentence case).
    static func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Header + card grouped as one unit. Hiding the returned view hides the
    /// whole section (weekly-chart enterprise gating hides at this level).
    static func makeSection(header: String, content: NSView) -> NSView {
        let headerLabel = makeSectionHeader(header)
        let stack = NSStackView(views: [headerLabel, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return stack
    }

    // MARK: Card chrome

    /// Rounded card that stacks pre-built units vertically. Divider management
    /// is the caller's job via `makeDividedUnit` (so a hidden unit collapses
    /// together with its divider).
    static func makeCard(units: [NSView]) -> NSView {
        let stack = NSStackView(views: units)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for unit in units {
            unit.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                unit.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                unit.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }

        let card = CardBackgroundView()
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    /// Row (or row group) preceded by an inset hairline divider. Conditional
    /// visibility must target the returned wrapper so the divider collapses
    /// with the row.
    static func makeDividedUnit(_ row: NSView) -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSStackView(views: [divider, row])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 0
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    // MARK: Rows

    /// Standard card row: title (+ optional caption) left, control trailing.
    /// Built on explicit required constraints, not NSStackView edgeInsets —
    /// the inset/centerY-alignment route rendered with the bottom padding
    /// partially swallowed (#101); hard anchors make the padding and the
    /// row's fitting height deterministic.
    static func makeCardRow(title: String, caption: String? = nil, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        if let caption {
            textStack.addArrangedSubview(makeCaption(caption))
        }

        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(textStack)
        host.addSubview(control)

        // Captioned rows breathe a little more — a wrapped caption against
        // a 10 pt bottom edge reads cramped (#101).
        let vPad: CGFloat = caption == nil ? 10 : 12
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: host.topAnchor, constant: vPad),
            textStack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -vPad),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 12),
            control.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor, constant: 6),
            control.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -6),
        ])
        return host
    }

    /// Wide content (e.g. the threshold slider) spanning the card width.
    /// The explicit pins are the #75 fix carried over: after `isHidden`
    /// cycles, the content settles back at full card width, never its
    /// intrinsic minimum.
    static func makeFullWidthCardRow(_ content: NSView) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
        ])
        return host
    }

    static func makeCaption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Must stay ≤ the real available width or long captions CLIP instead
        // of wrapping: intrinsic height is computed at this width, so a value
        // above the layout width yields a 1-line intrinsic that then gets
        // compressed. Available: contentWidth 440 − root insets 36 − row
        // insets 28 − spacing 12 − NSSwitch ≈ 54 → ≈ 310 (#101).
        label.preferredMaxLayoutWidth = 300
        return label
    }

    static func makeSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    // MARK: Tab root

    /// Root view for one tab: fixed content width, sections stacked with
    /// equal top/bottom padding. Bottom pin is `equalTo` so the tab's
    /// fitting size drives the per-tab window height.
    static func makeTabRoot(sections: [NSView], width: CGFloat = contentWidth) -> NSView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            section.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                section.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                section.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        return root
    }
}

// MARK: - CardBackgroundView

/// Card chrome with appearance-correct dynamic colors. `updateLayer()` is
/// AppKit's hook for resolving dynamic NSColors against the effective
/// appearance — a plain `layer.backgroundColor = ...` at init would bake in
/// whichever appearance was active then.
@MainActor
final class CardBackgroundView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
