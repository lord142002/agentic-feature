import AppKit

@MainActor
final class TextComposerController: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let field: NSTextField
    private let backdrop: NSVisualEffectView
    private let titleLabel: NSTextField
    private let hintLabel: NSTextField
    private var searchWeb = false
    var onSubmit: ((String, Bool) -> Void)?
    var onEscape: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = TextComposerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 126),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        field = NSTextField(frame: NSRect(x: 18, y: 37, width: 484, height: 39))
        backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 520, height: 126))
        titleLabel = NSTextField(labelWithString: "Ask Bibbles")
        hintLabel = NSTextField(labelWithString: "Return to ask  ·  Escape to close")
        super.init()
        field.placeholderString = "Ask about your work, a selection, or this screen…"
        field.font = .systemFont(ofSize: 16)
        field.focusRingType = .none
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 17, y: 84, width: 24, height: 24))
        icon.image = NSImage(named: NSImage.applicationIconName)
        titleLabel.frame = NSRect(x: 44, y: 85, width: 260, height: 20)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hintLabel.frame = NSRect(x: 18, y: 12, width: 480, height: 16)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        backdrop.addSubview(icon)
        backdrop.addSubview(titleLabel)
        backdrop.addSubview(field)
        backdrop.addSubview(hintLabel)
        panel.contentView = backdrop
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
    }

    func showNearCursor(searchWeb: Bool = false) {
        self.searchWeb = searchWeb
        titleLabel.stringValue = searchWeb ? "Quick web search" : "Ask Bibbles"
        hintLabel.stringValue = searchWeb ? "Return to search  ·  Escape to close" : "Return to ask  ·  Escape to close"
        field.placeholderString = searchWeb ? "Search the web for…" : "Ask about your work, a selection, or this screen…"
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
        let safe = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = panel.frame.size
        let x = min(max(cursor.x - size.width / 2, safe.minX + 12), safe.maxX - size.width - 12)
        let y = min(max(cursor.y - size.height - 24, safe.minY + 12), safe.maxY - size.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(field)
        onVisibilityChanged?()
    }

    func hide() {
        panel.orderOut(nil)
        onVisibilityChanged?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return true
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        submit()
        return true
    }

    private func submit() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        field.stringValue = ""
        panel.orderOut(nil)
        onVisibilityChanged?()
        onSubmit?(value, searchWeb)
    }
}

/// Borderless removes the title-bar controls; explicit key eligibility keeps typing working.
private final class TextComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
