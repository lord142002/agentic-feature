import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<FloatingPillView>
    private let model: InteractionModel
    private let onVisibilityChanged: () -> Void
    /// Set once the user drags the card; it then stays where they put it
    /// until it closes.
    private var userMoved = false
    private var lastPlacedOrigin: NSPoint?
    private var moveObserver: NSObjectProtocol?

    init(
        model: InteractionModel,
        meter: VoiceActivityMeter,
        voiceReply: VoiceReplyController,
        onOpenChat: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onVisibilityChanged: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onUseTranscriptAnyway: @escaping () -> Void,
        onToggleVoice: @escaping (String) -> Void,
        onInsert: @escaping (String) -> Void
    ) {
        self.model = model
        self.onVisibilityChanged = onVisibilityChanged
        hostingView = NSHostingView(rootView: FloatingPillView(
            model: model,
            meter: meter,
            voiceReply: voiceReply,
            onOpenChat: onOpenChat,
            onClose: onClose,
            onCancel: onCancel,
            onRetry: onRetry,
            onUseTranscriptAnyway: onUseTranscriptAnyway,
            onToggleVoice: onToggleVoice,
            onInsert: onInsert
        ))
        panel = DraggableCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = true
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Bibbles placed it somewhere else: the user dragged it.
                guard let self, let placed = self.lastPlacedOrigin,
                      self.panel.frame.origin != placed else { return }
                self.userMoved = true
            }
        }
    }

    private func place(_ frame: NSRect) {
        lastPlacedOrigin = frame.origin
        panel.setFrame(frame, display: true)
    }

    func showNearCursor(avoiding drawing: CGRect? = nil) {
        // Moved by the user: keep it where they put it, only resize.
        if userMoved, panel.isVisible {
            refreshVisibleContent()
            return
        }
        panel.ignoresMouseEvents = !model.state.usesInteractiveCard
        hostingView.layoutSubtreeIfNeeded()
        let ideal = hostingView.fittingSize
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
        let safe = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = NSSize(
            width: min(max(ideal.width, 160), safe.width - 16),
            height: min(max(ideal.height, 46), safe.height - 16)
        )
        var origin = NSPoint(x: cursor.x + 18, y: cursor.y - size.height - 18)
        if origin.x + size.width > safe.maxX { origin.x = cursor.x - size.width - 18 }
        if origin.y < safe.minY { origin.y = cursor.y + 18 }
        origin.x = min(max(origin.x, safe.minX + 8), safe.maxX - size.width - 8)
        origin.y = min(max(origin.y, safe.minY + 8), safe.maxY - size.height - 8)
        if let drawing, CGRect(origin: origin, size: size).intersects(drawing.insetBy(dx: -18, dy: -18)) {
            let candidates = [
                CGPoint(x: safe.minX + 8, y: safe.maxY - size.height - 8),
                CGPoint(x: safe.maxX - size.width - 8, y: safe.maxY - size.height - 8),
                CGPoint(x: safe.minX + 8, y: safe.minY + 8),
                CGPoint(x: safe.maxX - size.width - 8, y: safe.minY + 8)
            ]
            origin = candidates.min { a, b in
                let first = CGRect(origin: a, size: size).intersection(drawing)
                let second = CGRect(origin: b, size: size).intersection(drawing)
                let aArea = first.isNull ? 0 : first.width * first.height
                let bArea = second.isNull ? 0 : second.width * second.height
                return aArea < bArea
            } ?? origin
        }
        place(NSRect(origin: origin, size: size))
        panel.orderFrontRegardless()
        onVisibilityChanged()
    }

    func refreshVisibleContent() {
        guard panel.isVisible else {
            showNearCursor()
            return
        }
        panel.ignoresMouseEvents = !model.state.usesInteractiveCard
        hostingView.layoutSubtreeIfNeeded()
        let frame = panel.frame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        let safe = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let ideal = hostingView.fittingSize
        let size = NSSize(
            width: min(max(ideal.width, 160), safe.width - 16),
            height: min(max(ideal.height, 46), safe.height - 16)
        )
        let origin = NSPoint(
            x: min(max(frame.minX, safe.minX + 8), safe.maxX - size.width - 8),
            y: min(max(frame.maxY - size.height, safe.minY + 8), safe.maxY - size.height - 8)
        )
        place(NSRect(origin: origin, size: size))
    }

    func hide() {
        userMoved = false
        panel.orderOut(nil)
        onVisibilityChanged()
    }

    var isVisible: Bool { panel.isVisible }
}

/// The answer card moves with a click-and-hold drag from anywhere on it.
/// A plain click (moving less than a few points) still goes to buttons and
/// text as usual; once the pointer moves further, the card follows it and
/// whatever was under the click is released without acting.
final class DraggableCardPanel: NSPanel {
    private var pressed = false
    private var dragging = false
    private var startPointer = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private static let threshold: CGFloat = 4

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressed = true
            dragging = false
            startPointer = NSEvent.mouseLocation
            startOrigin = frame.origin
            super.sendEvent(event)
        case .leftMouseDragged where pressed:
            let now = NSEvent.mouseLocation
            let dx = now.x - startPointer.x, dy = now.y - startPointer.y
            if !dragging {
                guard hypot(dx, dy) >= Self.threshold else { super.sendEvent(event); return }
                dragging = true
                releaseContent(after: event)
            }
            setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        case .leftMouseUp where dragging:
            // The move is done; the content already had its release.
            pressed = false
            dragging = false
        case .leftMouseUp:
            pressed = false
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }

    /// Ends the click inside the card far outside every control, so a button
    /// pressed at the start of the drag doesn't fire.
    private func releaseContent(after event: NSEvent) {
        guard let release = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: [],
            timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: 1, pressure: 0) else { return }
        super.sendEvent(release)
    }
}
