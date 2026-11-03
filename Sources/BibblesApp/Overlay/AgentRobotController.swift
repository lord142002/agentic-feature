#if BIBBLES_DEVELOPER
import AppKit
import Combine
import ImageIO
import QuartzCore

/// The agent robot, in the top-right corner of the screen while an agent task
/// is open. It is the agent's only thing on screen:
/// - working (looking, planning, running, stopping, undoing): the robot plays;
/// - needs you (a plan to start, a "Send?" to answer, an error): a red 1 on it;
/// - clicking it opens the agent card below it;
/// - done: it stays, resting (the result also shows in Bibbles' answer card);
/// - right-click (or Control-click): Open agent card / Hide robot. A hidden
///   robot comes back when the agent needs the user, or with the next task.
/// Bibbles' screenshots leave it out, so the agent never sees it.
@MainActor
final class AgentRobotController {
    static let shared = AgentRobotController()

    static let size = NSSize(width: 96, height: 96)
    static let margin: CGFloat = 12

    /// Resources/AgentRobot.png: 72 frames of 192×192 pixels, 12 per row, 24 frames a second.
    static let frameSide = 192
    static let columns = 12
    static let frameCount = 72
    static let loopDuration: CFTimeInterval = 3

    /// Clicking the robot (opens or closes the agent card).
    var onClick: (() -> Void)?
    /// "Hide robot" chosen: the card closes too.
    var onHide: (() -> Void)?

    private var panel: NSPanel?
    private let robotLayer = CALayer()
    private let badge = AgentRobotBadge()
    private var watch: AnyCancellable?
    private var hideWork: DispatchWorkItem?
    /// Changes on every show, so a fade-out that finishes late never hides a robot shown again.
    private var showCount = 0
    /// An error the user has already seen and closed: no badge for it any more.
    private var errorSeen = false
    /// The user chose "Hide robot": it stays hidden until the agent needs them or a new task starts.
    private var userHidden = false
    /// The look for the agent's current state (re-checked when the card closes).
    private var currentLook: (() -> Look)?
    private lazy var frames: [CGImage] = Self.loadFrames()

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }
    /// The robot's frame on screen (AppKit coordinates), for placing the card under it.
    var frame: NSRect? { panel?.frame }

    /// What the robot should show for an agent's state.
    struct Look: Equatable {
        var visible: Bool
        var badge: Bool
        /// Clicks pass through while the agent itself clicks on screen.
        var clickThrough: Bool
        static let hidden = Look(visible: false, badge: false, clickThrough: true)
        /// Nothing to do: the robot stays until the user hides it (right-click).
        static let resting = Look(visible: true, badge: false, clickThrough: false)
    }

    nonisolated static func look(screen phase: ScreenAgentSession.Phase, asking: Bool, errorSeen: Bool) -> Look {
        if asking { return Look(visible: true, badge: true, clickThrough: false) }
        switch phase {
        case .preview: return Look(visible: true, badge: true, clickThrough: false)
        case .running, .stopping: return Look(visible: true, badge: false, clickThrough: true)
        case .looking, .planning, .undoing: return Look(visible: true, badge: false, clickThrough: false)
        case .failed: return errorSeen ? .resting : Look(visible: true, badge: true, clickThrough: false)
        case .done, .undone: return .resting
        }
    }

    nonisolated static func look(files phase: FilesAgentSession.Phase, errorSeen: Bool) -> Look {
        switch phase {
        case .preview: return Look(visible: true, badge: true, clickThrough: false)
        case .running, .stopping: return Look(visible: true, badge: false, clickThrough: true)
        case .scanning, .planning, .undoing: return Look(visible: true, badge: false, clickThrough: false)
        case .failed: return errorSeen ? .resting : Look(visible: true, badge: true, clickThrough: false)
        case .done, .undone: return .resting
        }
    }

    func follow(_ session: ScreenAgentSession) {
        errorSeen = false
        userHidden = false
        currentLook = { [weak self, weak session] in
            guard let self, let session else { return .resting }
            return Self.look(screen: session.phase, asking: session.pendingConfirmation != nil, errorSeen: self.errorSeen)
        }
        watch = session.$phase.combineLatest(session.$pendingConfirmation).sink { [weak self] phase, asking in
            guard let self else { return }
            self.apply(Self.look(screen: phase, asking: asking != nil, errorSeen: self.errorSeen))
        }
    }

    func follow(_ session: FilesAgentSession) {
        errorSeen = false
        userHidden = false
        currentLook = { [weak self, weak session] in
            guard let self, let session else { return .resting }
            return Self.look(files: session.phase, errorSeen: self.errorSeen)
        }
        watch = session.$phase.sink { [weak self] phase in
            guard let self else { return }
            self.apply(Self.look(files: phase, errorSeen: self.errorSeen))
        }
    }

    /// The card was closed: an error in it has been seen (no more red 1 for it).
    func cardClosed(stillWorking: Bool) {
        errorSeen = true
        if let look = currentLook?() { apply(look) }
    }

    /// No task yet: the robot rests in the corner, ready for one (click it).
    func showIdle() {
        userHidden = false
        errorSeen = false
        watch = nil
        currentLook = { .resting }
        apply(.resting)
    }

    /// Right-click → "Hide robot".
    func hideByUser() {
        userHidden = true
        onHide?()
        apply(.hidden)
    }

    /// Runs `body` with the robot briefly hidden (an Accessibility look at a
    /// point the robot covers must see the app underneath, not the robot).
    func hidden<T>(_ body: () -> T) -> T {
        guard let panel, panel.isVisible else { return body() }
        panel.orderOut(nil)
        defer { panel.orderFrontRegardless() }
        return body()
    }

    private func apply(_ look: Look) {
        hideWork?.cancel()
        hideWork = nil
        // Hidden by the user: only "the agent needs you" brings it back.
        if userHidden, look.badge { userHidden = false }
        guard look.visible, !userHidden else {
            // A short pause, so the robot doesn't flicker between an agent's parts.
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            return
        }
        show()
        panel?.ignoresMouseEvents = look.clickThrough
        badge.isHidden = !look.badge
    }

    private func show() {
        guard !frames.isEmpty else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        showCount += 1
        if panel.isVisible {
            // Still on screen (perhaps fading out): bring it back to full.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (frame.maxX - Self.size.width - Self.margin).rounded(),
                                         y: (frame.maxY - Self.size.height - Self.margin).rounded()))
        }
        startAnimation()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        let shown = showCount
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.showCount == shown else { return }
                panel.orderOut(nil)
                self.robotLayer.removeAllAnimations()
                self.badge.isHidden = true
            }
        })
    }

    private func startAnimation() {
        robotLayer.removeAllAnimations()
        robotLayer.contents = frames.first
        // Reduce motion: a still robot.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, frames.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = Self.loopDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        robotLayer.add(animation, forKey: "robot")
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = AgentRobotView(frame: NSRect(origin: .zero, size: Self.size))
        view.onClick = { [weak self] in self?.onClick?() }
        view.onOpenCard = { [weak self] in self?.onClick?() }
        view.onHideRobot = { [weak self] in self?.hideByUser() }
        view.wantsLayer = true
        robotLayer.frame = view.bounds
        robotLayer.contentsGravity = .resizeAspect
        robotLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        view.layer?.addSublayer(robotLayer)
        // The red 1, at the robot's top right.
        badge.frame = NSRect(x: Self.size.width - 30, y: Self.size.height - 30, width: 22, height: 22)
        badge.isHidden = true
        view.addSubview(badge)
        panel.contentView = view
        return panel
    }

    /// Cuts the sprite sheet into frames (empty when the image is missing).
    static func loadFrames(bundle: Bundle = .main) -> [CGImage] {
        guard let url = bundle.url(forResource: "AgentRobot", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return frames(from: sheet)
    }

    static func frames(from sheet: CGImage) -> [CGImage] {
        (0..<frameCount).compactMap { index in
            let rect = CGRect(x: (index % columns) * frameSide, y: (index / columns) * frameSide,
                              width: frameSide, height: frameSide)
            return sheet.cropping(to: rect)
        }
    }
}

/// The robot's view: a click opens the agent card; right-click (or Control-click)
/// offers Open agent card / Hide robot. A pointing hand shows it can be clicked.
private final class AgentRobotView: NSView {
    var onClick: (() -> Void)?
    var onOpenCard: (() -> Void)?
    var onHideRobot: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu(for: event) } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

    override func menu(for event: NSEvent) -> NSMenu? { robotMenu() }

    private func showMenu(for event: NSEvent) {
        NSMenu.popUpContextMenu(robotMenu(), with: event, for: self)
    }

    private func robotMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open agent card", action: #selector(openCard), keyEquivalent: "")
        open.target = self
        let hide = NSMenuItem(title: "Hide robot", action: #selector(hideRobot), keyEquivalent: "")
        hide.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(hide)
        return menu
    }

    @objc private func openCard() { onOpenCard?() }
    @objc private func hideRobot() { onHideRobot?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Bibbles agent" }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The red "1": the agent needs you.
private final class AgentRobotBadge: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = 11
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 2
        let label = NSTextField(labelWithString: "1")
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 3, width: 22, height: 16)
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
}
#endif
