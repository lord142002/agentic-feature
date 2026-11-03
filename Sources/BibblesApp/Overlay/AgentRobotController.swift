#if BIBBLES_DEVELOPER
import AppKit
import Combine
import ImageIO
import QuartzCore

/// The agent robot: a small animated robot in the top-right corner of the
/// screen while an agent works (looking, planning, running, stopping, undoing).
/// It hides when the agent waits for the user or finishes. Clicks pass through
/// it, and Bibbles' own screenshots leave it out, so the agent never sees it.
@MainActor
final class AgentRobotController {
    static let shared = AgentRobotController()

    static let size = NSSize(width: 96, height: 96)
    static let margin: CGFloat = 12
    /// Room the Screen agent's card leaves above itself for the robot.
    static var reservedHeight: CGFloat { size.height + margin }

    /// Resources/AgentRobot.png: 72 frames of 192×192 pixels, 12 per row, 24 frames a second.
    static let frameSide = 192
    static let columns = 12
    static let frameCount = 72
    static let loopDuration: CFTimeInterval = 3

    private var panel: NSPanel?
    private let robotLayer = CALayer()
    private var watch: AnyCancellable?
    private var hideWork: DispatchWorkItem?
    /// Changes on every show, so a fade-out that finishes late never hides a robot shown again.
    private var showCount = 0
    private lazy var frames: [CGImage] = Self.loadFrames()

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func follow(_ session: ScreenAgentSession) {
        watch = session.$phase.sink { [weak self] phase in
            switch phase {
            case .looking, .planning, .running, .stopping, .undoing: self?.setWorking(true)
            default: self?.setWorking(false)
            }
        }
    }

    func follow(_ session: FilesAgentSession) {
        watch = session.$phase.sink { [weak self] phase in
            switch phase {
            case .scanning, .planning, .running, .stopping, .undoing: self?.setWorking(true)
            default: self?.setWorking(false)
            }
        }
    }

    /// Runs `body` with the robot briefly hidden (an Accessibility look at a
    /// point the robot covers must see the app underneath, not the robot).
    func hidden<T>(_ body: () -> T) -> T {
        guard let panel, panel.isVisible else { return body() }
        panel.orderOut(nil)
        defer { panel.orderFrontRegardless() }
        return body()
    }

    private func setWorking(_ working: Bool) {
        hideWork?.cancel()
        hideWork = nil
        if working {
            show()
        } else {
            // A short pause, so the robot doesn't flicker between an agent's parts.
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
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
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        robotLayer.frame = view.bounds
        robotLayer.contentsGravity = .resizeAspect
        robotLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        view.layer?.addSublayer(robotLayer)
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
#endif
