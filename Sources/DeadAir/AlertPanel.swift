import AppKit

/// A floating banner that shows over everything (including full-screen apps)
/// without stealing focus. Used instead of notifications because those are
/// usually silenced while recording.
@MainActor
final class AlertPanel {
    var onDismiss: () -> Void = {}
    var onDisarm: () -> Void = {}

    private let panel: NSPanel
    private let background = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Best effort at keeping the banner out of screen recordings. Some capture
        // APIs on newer macOS versions ignore this.
        panel.sharingType = .none

        background.wantsLayer = true
        background.layer?.cornerRadius = 14

        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        detailLabel.preferredMaxLayoutWidth = 400

        let dismiss = NSButton(title: "Dismiss", target: nil, action: nil)
        dismiss.keyEquivalent = "\u{1b}"
        let disarm = NSButton(title: "Disarm", target: nil, action: nil)
        dismiss.onClick { [weak self] in self?.onDismiss() }
        disarm.onClick { [weak self] in self?.onDisarm() }

        let buttons = NSStackView(views: [NSView(), disarm, dismiss])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [titleLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            background.widthAnchor.constraint(equalToConstant: 440),
        ])
        panel.contentView = background
    }

    func showDead(title: String, detail: String) {
        show(title: title, detail: detail, color: .systemRed)
    }

    func showRecovered(title: String, detail: String) {
        show(title: title, detail: detail, color: NSColor.systemOrange.blended(withFraction: 0.25, of: .black)!)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show(title: String, detail: String, color: NSColor) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        background.layer?.backgroundColor = color.cgColor
        if !panel.isVisible {
            background.layoutSubtreeIfNeeded()
            panel.setContentSize(background.fittingSize)
            position()
            panel.orderFrontRegardless()
        }
    }

    /// Top-centre of whichever screen the pointer is on — most likely the one you're looking at.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24))
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension NSControl {
    private static var handlerKey = 0

    /// Closure-based target/action.
    func onClick(_ handler: @escaping () -> Void) {
        let box = ActionBox(handler)
        objc_setAssociatedObject(self, &NSControl.handlerKey, box, .OBJC_ASSOCIATION_RETAIN)
        target = box
        action = #selector(ActionBox.fire)
    }
}

final class ActionBox: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
