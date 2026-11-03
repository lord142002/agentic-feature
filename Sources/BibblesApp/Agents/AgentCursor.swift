#if BIBBLES_DEVELOPER
import AppKit
import QuartzCore

/// Bibbles' own red pointer while an agent works: it glides to each thing the
/// agent uses and pulses when it clicks. The user's pointer is put back where
/// they left it after each mouse action (see `ScreenExecutor.run`).
@MainActor
final class AgentCursor {
    static let shared = AgentCursor()

    /// Where the arrow's tip sits inside the small window (from the top left).
    static let tip = CGPoint(x: 20, y: 20)
    static let size = CGSize(width: 64, height: 64)

    private var panel: NSPanel?
    private var view: AgentCursorView?
    /// Top-left screen coordinates, like the agent's clicks.
    private(set) var location: CGPoint?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if location == nil, let mouse = CGEvent(source: nil)?.location { place(at: mouse) }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        location = nil
    }

    /// Moves smoothly to `point` (top-left screen coordinates).
    func glide(to point: CGPoint) async {
        guard isVisible else { return }
        let start = location ?? point
        let distance = hypot(point.x - start.x, point.y - start.y)
        guard distance > 2 else { place(at: point); return }
        let frames = max(6, min(21, Int(distance / 60)))
        for frame in 1...frames {
            let t = Double(frame) / Double(frames)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            place(at: CGPoint(x: start.x + (point.x - start.x) * eased, y: start.y + (point.y - start.y) * eased))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    func place(at point: CGPoint) {
        location = point
        guard let panel else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrameOrigin(NSPoint(x: point.x - Self.tip.x, y: primaryHeight - point.y - (Self.size.height - Self.tip.y)))
    }

    func pulse() {
        guard isVisible else { return }
        view?.pulse()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Clicks go straight through to the app underneath.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = AgentCursorView(frame: NSRect(origin: .zero, size: Self.size))
        panel.contentView = view
        self.view = view
        return panel
    }
}

/// A red arrow with a white edge, and a ring that pulses on each click.
final class AgentCursorView: NSView {
    private let ring = CAShapeLayer()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let radius: CGFloat = 13
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.fillColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
        ring.strokeColor = NSColor.systemRed.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Flipped view: (tip.x, tip.y) is the arrow's tip from the top left.
        ring.position = AgentCursor.tip
    }

    override func draw(_ dirtyRect: NSRect) {
        let tip = AgentCursor.tip
        let offsets: [(CGFloat, CGFloat)] = [(0, 0), (0, 25), (6, 19.5), (10.5, 29), (14.5, 27.2), (10, 18), (18, 18)]
        let shape = offsets.map { CGPoint(x: tip.x + $0.0, y: tip.y + $0.1) }
        let arrow = NSBezierPath()
        arrow.move(to: shape[0])
        shape.dropFirst().forEach { arrow.line(to: $0) }
        arrow.close()
        arrow.lineJoinStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.systemRed.setFill()
        arrow.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.6
        arrow.stroke()
    }

    func pulse() {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
    }
}
#endif
