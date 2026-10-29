import AppKit
import QuartzCore

@MainActor
private final class CircleFocusCanvas: NSView {
    var onDown: (() -> Void)?
    var onPoint: ((CGPoint) -> Void)?
    var onUp: ((CGPoint) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) { onDown?(); onPoint?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onPoint?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onUp?(NSEvent.mouseLocation) }
}

/// Only the armed panels receive pointer events. All fading artwork is click-through.
@MainActor
final class CircleFocusController {
    var onDragBegan: (() -> Void)?
    var onSelection: ((CircleFocusSelection) -> Void)?
    var onVisibilityChanged: (() -> Void)?
    private var panels: [NSPanel] = []
    private var selectedPanel: NSPanel?
    private var gesture = CircleFocusGesture()
    private var selectionDisplay: CircleFocusSelection?
    private var armed = false
    private var suppressedUntilRelease = false
    private var trails: [(layer: CALayer, date: Date)] = []
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private let lavender = NSColor(srgbRed: 230 / 255, green: 230 / 255, blue: 250 / 255, alpha: 1)

    var isDrawing: Bool { selectedPanel != nil }
    var isActive: Bool { armed || isDrawing || !trails.isEmpty }

    static func chordHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.control, .option, .command, .shift, .function]) == [.control, .option]
    }

    func start() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancel() } }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancel() } }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        cancel()
        timer?.invalidate(); timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        screenObserver = nil; spaceObserver = nil
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = Self.chordHeld(flags)
        if !held {
            suppressedUntilRelease = false
            if armed || isDrawing {
                armed = false
                gesture.clear()
                selectedPanel = nil
                selectionDisplay = nil
                panels.forEach { $0.ignoresMouseEvents = true }
                onVisibilityChanged?()
            }
            if trails.isEmpty { closePanels() }
        } else if !armed && !suppressedUntilRelease {
            arm()
        }
    }

    func cancel() {
        suppressedUntilRelease = Self.chordHeld(NSEvent.modifierFlags)
        armed = false
        gesture.clear()
        selectedPanel = nil
        selectionDisplay = nil
        trails.forEach { $0.layer.removeAllAnimations(); $0.layer.removeFromSuperlayer() }
        trails.removeAll(keepingCapacity: false)
        closePanels()
    }

    private func tick() {
        // Also catches dropped modifier notifications; release restores passthrough immediately.
        modifiersChanged(NSEvent.modifierFlags)
        let cutoff = Date().addingTimeInterval(-0.36)
        trails.removeAll { item in
            guard item.date < cutoff else { return false }
            item.layer.removeAllAnimations()
            item.layer.removeFromSuperlayer()
            return true
        }
        if !armed && !isDrawing && trails.isEmpty { closePanels() }
    }

    private func arm() {
        trails.forEach { $0.layer.removeAllAnimations(); $0.layer.removeFromSuperlayer() }
        trails.removeAll(keepingCapacity: false)
        closePanels()
        armed = true
        ensureTimer()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = false
            let canvas = CircleFocusCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
            canvas.wantsLayer = true
            canvas.layer?.contentsScale = screen.backingScaleFactor
            canvas.onDown = { [weak self, weak panel] in
                guard let panel else { return }
                self?.begin(on: panel, screen: screen)
            }
            canvas.onPoint = { [weak self] point in self?.append(point) }
            canvas.onUp = { [weak self] point in self?.finish(at: point) }
            panel.contentView = canvas
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        onVisibilityChanged?()
    }

    private func begin(on panel: NSPanel, screen: NSScreen) {
        guard armed, Self.chordHeld(NSEvent.modifierFlags),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { cancel(); return }
        trails.forEach { $0.layer.removeFromSuperlayer() }
        trails.removeAll(keepingCapacity: false)
        selectedPanel = panel
        let id = CGDirectDisplayID(number.uint32Value)
        selectionDisplay = CircleFocusSelection(rect: .zero, displayID: id, displayFrame: screen.frame,
            scale: screen.backingScaleFactor, rotation: Int(CGDisplayRotation(id).rounded()) % 360)
        gesture.begin(at: NSEvent.mouseLocation, in: screen.frame)
        onDragBegan?()
    }

    private func append(_ point: CGPoint) {
        guard armed, Self.chordHeld(NSEvent.modifierFlags) else { modifiersChanged(NSEvent.modifierFlags); return }
        if let curve = gesture.append(point) { draw(curve) }
    }

    private func finish(at point: CGPoint) {
        guard armed, Self.chordHeld(NSEvent.modifierFlags), let display = selectionDisplay else { cancel(); return }
        append(point)
        let result = gesture.finish() // Frees every gesture point before callbacks or capture.
        if let curve = result.curve { draw(curve) }
        armed = false
        suppressedUntilRelease = true
        panels.forEach { $0.ignoresMouseEvents = true }
        if let rect = result.rect {
            highlight(rect)
            selectedPanel = nil
            selectionDisplay = nil
            onSelection?(CircleFocusSelection(rect: rect, displayID: display.displayID,
                displayFrame: display.displayFrame, scale: display.scale, rotation: display.rotation))
        } else {
            selectedPanel = nil
            selectionDisplay = nil
        }
        onVisibilityChanged?()
    }

    private func draw(_ curve: FocusCurve) {
        guard let panel = selectedPanel, let root = panel.contentView?.layer else { return }
        var transform = CGAffineTransform(translationX: -panel.frame.minX, y: -panel.frame.minY)
        let layer = CAShapeLayer()
        layer.path = curve.path.copy(using: &transform)
        layer.fillColor = nil
        layer.strokeColor = lavender.cgColor
        layer.lineCap = .round
        layer.lineWidth = 4
        layer.shadowColor = lavender.cgColor
        layer.shadowOpacity = 0.8
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
        layer.contentsScale = panel.backingScaleFactor
        root.addSublayer(layer)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        fade.duration = reduced ? 0.1 : 0.3
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "decay")
        let taper = CABasicAnimation(keyPath: "lineWidth")
        taper.fromValue = 4; taper.toValue = 0.15
        taper.duration = fade.duration
        taper.fillMode = .forwards; taper.isRemovedOnCompletion = false
        layer.add(taper, forKey: "taper")
        trails.append((layer, Date()))
        // Hard cap as well as time decay, so high-rate mice cannot grow the canvas.
        if trails.count > 96 { trails.removeFirst().layer.removeFromSuperlayer() }
    }

    private func highlight(_ rect: CGRect) {
        guard let panel = selectedPanel, let root = panel.contentView?.layer else { return }
        let layer = CAShapeLayer()
        let path = CGMutablePath()
        path.addRoundedRect(in: rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY), cornerWidth: 8, cornerHeight: 8)
        layer.path = path
        layer.fillColor = lavender.withAlphaComponent(0.07).cgColor
        layer.strokeColor = lavender.cgColor
        layer.lineWidth = 3
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.3; layer.shadowRadius = 3
        root.addSublayer(layer)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.3
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "highlight")
        trails.append((layer, Date()))
    }

    private func closePanels() {
        panels.forEach { $0.ignoresMouseEvents = true; $0.orderOut(nil); $0.contentView = nil }
        panels.removeAll(keepingCapacity: false)
        if !armed && trails.isEmpty { timer?.invalidate(); timer = nil }
        onVisibilityChanged?()
    }
}
