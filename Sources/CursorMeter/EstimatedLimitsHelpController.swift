import AppKit

@MainActor
final class EstimatedLimitsHelpController: NSViewController, NSPopoverDelegate {
    private let popover = NSPopover()
    private weak var anchorButton: NSButton?
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var restoreFocus = false
    var onShow: (() -> Void)?

    var isShown: Bool { popover.isShown }

    init() {
        super.init(nibName: nil, bundle: nil)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init()") }

    override func loadView() {
        let heading = NSTextField(labelWithString: "About estimated limits")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let bullets = [
            "Unofficial limits estimated from sufficient matching usage and cost history.",
            "Plan changes or usage spilling into another pool can require revalidation.",
            "Circles and alerts use reported percentages.",
        ].map { text in
            let label = NSTextField(wrappingLabelWithString: "• " + text)
            label.font = .systemFont(ofSize: 12)
            label.preferredMaxLayoutWidth = 288
            return label
        }
        closeButton.target = self
        closeButton.action = #selector(closeHelp)
        closeButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [SettingsCardFactory.makeSpacer(), closeButton])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [heading] + bullets + [footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let root = NSView()
        root.setAccessibilityLabel("About estimated limits")
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 320),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for label in bullets {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = root
        preferredContentSize = root.fittingSize
    }

    @discardableResult
    func show(relativeTo button: NSButton) -> Bool {
        guard let window = button.window, window.isVisible,
              !button.isHiddenOrHasHiddenAncestor, !button.bounds.isEmpty else { return false }
        anchorButton = button
        restoreFocus = false
        if popover.isShown { return true }
        popover.contentViewController = self
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX)
        if popover.isShown { view.window?.makeFirstResponder(closeButton) }
        return popover.isShown
    }

    func popoverDidShow(_ notification: Notification) {
        onShow?()
    }

    func popoverDidClose(_ notification: Notification) {
        if restoreFocus, let button = anchorButton {
            button.window?.makeFirstResponder(button)
        }
        restoreFocus = false
        // The controller owns the popover; release the inverse ownership on close.
        popover.contentViewController = nil
    }

    override func cancelOperation(_ sender: Any?) {
        closeHelp()
    }

    @objc private func closeHelp() {
        restoreFocus = true
        popover.performClose(nil)
    }
}

@MainActor
final class KeyboardAccessibleInfoButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}
