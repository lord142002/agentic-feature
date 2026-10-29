import AppKit
import QuartzCore

@MainActor
final class TargetHighlightController {
    private var panel: NSPanel?
    private var root: CALayer?
    private var displayFrame = CGRect.zero
    private var safeFrame = CGRect.zero
    private var scale: CGFloat = 2
    private var marks: [DoodleMark] = []
    private var isLocalDrawing = false
    /// A step-by-step walkthrough: every mark is the model's own placement,
    /// so marks may touch or overlap (side a meets side b at a corner).
    private var walkthroughMode = false
    private var dismissTask: Task<Void, Never>?
    private var artworkBounds: CGRect?
    private var screenObserver: NSObjectProtocol?
    /// Stop any pending walkthrough steps too, otherwise a later timer can
    /// recreate marks calculated for the previous display arrangement.
    var onDisplayChange: (() -> Void)?

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
                self?.onDisplayChange?()
            }
        }
    }

    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }

    var canUndoDrawing: Bool { isLocalDrawing && !marks.isEmpty }
    var hasDrawing: Bool { !marks.isEmpty }

    var visibleBounds: CGRect? {
        artworkBounds
    }

    @discardableResult
    func draw(_ shape: DoodleShape, at point: CGPoint, tone: DoodleTone = .violet, request: String = "") -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        let point = AnnotationGeometry.relativePoint(in: screen.visibleFrame, request: request, pointer: point)
        if !isLocalDrawing || panel == nil || displayFrame != screen.frame {
            hide()
            makePanel(on: screen)
            isLocalDrawing = true
        }
        marks.append(DoodleMark(shape: shape, rect: DoodleArtwork.localRect(around: point, within: screen.visibleFrame, shape: shape), tone: tone))
        if marks.count > 12 { marks.removeFirst() }
        render(animatedIndex: marks.count - 1)
        return true
    }

    @discardableResult
    func undoDrawing() -> Bool {
        guard isLocalDrawing, !marks.isEmpty else { return false }
        marks.removeLast()
        if marks.isEmpty { hide() } else { render(animatedIndex: nil) }
        return true
    }

    func showScanning(at point: CGPoint) {
        hide()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        makePanel(on: screen)
        let local = convert(point)
        let ring = DoodleArtwork.stroke(
            DoodleArtwork.path(for: .circle, in: CGRect(x: local.x - 19, y: local.y - 19, width: 38, height: 38)),
            tone: .violet, animated: false
        )
        root?.addSublayer(ring)
        root?.addSublayer(DoodleArtwork.companion(at: clamp(CGPoint(x: local.x + 30, y: local.y + 26))))
        if !reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.4
            pulse.toValue = 1
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            ring.add(pulse, forKey: "search")
        }
        scheduleDismissal(after: 12_000_000_000)
    }

    func show(rect: CGRect, from point: CGPoint?, durationNanoseconds: UInt64 = 12_000_000_000) {
        showGuidance([DoodleMark(shape: .rectangle, rect: rect, from: point)], durationNanoseconds: durationNanoseconds)
    }

    func showGuidance(_ annotations: [DoodleMark], durationNanoseconds: UInt64 = 12_000_000_000) {
        hide()
        guard let first = annotations.first,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(first.rect) }) else { return }
        makePanel(on: screen)
        marks = Array(annotations.filter { AnnotationGeometry.isValid($0.rect) && screen.frame.contains($0.rect) }.prefix(4))
        render(animatedIndex: -1)
        scheduleDismissal(after: durationNanoseconds)
    }

    /// Shows the walkthrough so far: earlier steps stay drawn, the newest one
    /// is drawn in with animation. The panel is kept between steps.
    func showWalkthrough(_ shown: [DoodleMark], durationNanoseconds: UInt64 = 25_000_000_000) {
        guard let last = shown.last,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(last.rect) }) else { return }
        if !walkthroughMode || panel == nil || displayFrame != screen.frame {
            hide()
            makePanel(on: screen)
            walkthroughMode = true
        }
        dismissTask?.cancel()
        marks = shown.filter { screen.frame.intersects($0.rect) }
        render(animatedIndex: marks.count - 1)
        scheduleDismissal(after: durationNanoseconds)
    }

    var isShowingWalkthrough: Bool { walkthroughMode && panel != nil }

    /// Ending a remote walkthrough must not erase the user's local canvas;
    /// otherwise "undo drawing" loses its history before it can run.
    func endWalkthrough() {
        if walkthroughMode { hide() }
    }

    func hide() {
        walkthroughMode = false
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
        root = nil
        marks.removeAll()
        artworkBounds = nil
        isLocalDrawing = false
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func render(animatedIndex: Int?) {
        guard let root else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = nil
        let bounds = safeFrame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY).insetBy(dx: 8, dy: 8)
        var labelFrames: [CGRect] = []
        var drawnBounds = CGRect.null
        let targets = marks.map { $0.rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY) }
        if marks.contains(where: { $0.shape == .spotlight }) {
            let mask = CAShapeLayer()
            let cutouts = CGMutablePath()
            cutouts.addRect(root.bounds)
            if let index = marks.firstIndex(where: { $0.shape == .spotlight }) {
                cutouts.addRoundedRect(in: targets[index].insetBy(dx: -4, dy: -4), cornerWidth: 8, cornerHeight: 8)
            }
            mask.path = cutouts
            mask.fillRule = .evenOdd
            mask.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor
            root.addSublayer(mask)
        }
        var pathFrames: [CGRect] = []
        for (index, mark) in marks.enumerated() {
            let rect = mark.rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
            let animated = !reduceMotion && (animatedIndex == -1 || animatedIndex == index)
            let from = mark.from.map(convert)
            let path: CGPath
            var arrowEndpoints: (CGPoint, CGPoint)?
            if let points = mark.points, points.count >= 2 {
                // Traced along the real drawing (a side, edge, axis or outline).
                let traced = CGMutablePath()
                traced.addLines(between: points.map(convert))
                path = traced
            } else if mark.shape == .arrow, !isLocalDrawing {
                guard let (start, end) = AnnotationGeometry.arrow(to: rect, from: from, within: bounds) else { continue }
                arrowEndpoints = (start, end)
                path = DoodleArtwork.arrow(from: start, to: end)
            } else {
                var padded = isLocalDrawing ? rect : rect.insetBy(dx: -4, dy: -4)
                var shape = mark.shape
                // Walkthrough: draw just inside the piece, so pieces that share
                // an edge don't get doubled, overlapping outlines.
                let insideWalkthrough = walkthroughMode && rect.width > 24 && rect.height > 24
                if insideWalkthrough { padded = rect.insetBy(dx: 3, dy: 3) }
                if !isLocalDrawing, !insideWalkthrough, shape == .circle {
                    let diameter = hypot(rect.width, rect.height) + 8
                    padded = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
                    if !bounds.contains(padded) { shape = .rectangle; padded = rect.insetBy(dx: -4, dy: -4) }
                }
                path = DoodleArtwork.path(for: shape, in: padded)
            }
            let frame = path.boundingBoxOfPath.insetBy(dx: -4, dy: -4)
            if !isLocalDrawing, !walkthroughMode, targets.enumerated().contains(where: { $0.offset != index && $0.element.intersects(frame) }) { continue }
            if !isLocalDrawing, !walkthroughMode, pathFrames.contains(where: { $0.intersects(frame) }) { continue }
            let strokeLayer: CALayer
            if let (start, end) = arrowEndpoints {
                strokeLayer = DoodleArtwork.arrowStroke(from: start, to: end, tone: mark.tone, animated: animated, dotted: mark.dotted)
            } else {
                strokeLayer = DoodleArtwork.stroke(path, tone: mark.tone, animated: animated, dotted: mark.dotted)
            }
            root.addSublayer(strokeLayer)
            pathFrames.append(frame)
            drawnBounds = drawnBounds.union(path.boundingBoxOfPath)
        }
        for (index, mark) in marks.enumerated() {
            let rect = targets[index]
            if let label = mark.label, !label.isEmpty {
                let blocked = walkthroughMode
                    ? labelFrames
                    : labelFrames + targets.map { $0.insetBy(dx: -7, dy: -7) } + pathFrames
                // Walkthrough: the label goes inside its own piece (top-left
                // corner) when it fits, so it can't look like a neighbour's.
                let fitsInside = walkthroughMode && mark.points == nil && rect.width >= 90 && rect.height >= 52
                let locations = (fitsInside ? [CGPoint(x: rect.minX + 9, y: rect.maxY - 37)] : []) + [CGPoint(x: rect.minX, y: rect.maxY + 12),
                                 CGPoint(x: rect.minX, y: rect.minY - 42),
                                 CGPoint(x: rect.maxX + 14, y: rect.midY),
                                 CGPoint(x: rect.minX, y: rect.maxY + 48)]
                for location in locations {
                    let badge = DoodleArtwork.badge("\(mark.step ?? index + 1) · \(label)", at: location, within: bounds, tone: mark.tone, scale: scale)
                    if !blocked.contains(where: { $0.intersects(badge.frame) }) {
                        root.addSublayer(badge)
                        labelFrames.append(badge.frame)
                        drawnBounds = drawnBounds.union(badge.frame)
                        break
                    }
                }
            }
        }
        if isLocalDrawing, let last = marks.last {
            let rect = last.rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
            let end = clamp(CGPoint(x: rect.maxX + 26, y: rect.minY - 22))
            let companion = DoodleArtwork.companion(at: end, tone: last.tone)
            root.addSublayer(companion)
            drawnBounds = drawnBounds.union(companion.frame)
            if !reduceMotion, animatedIndex != nil, let from = last.from, displayFrame.contains(from) {
                let glide = CABasicAnimation(keyPath: "position")
                glide.fromValue = NSValue(point: convert(from))
                glide.toValue = NSValue(point: end)
                glide.duration = 0.3
                glide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                companion.add(glide, forKey: "glide")
            }
        }
        artworkBounds = drawnBounds.isNull ? nil : drawnBounds.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
        CATransaction.commit()
    }

    private func convert(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - displayFrame.minX, y: point.y - displayFrame.minY)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let local = safeFrame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY).insetBy(dx: 20, dy: 20)
        return CGPoint(x: min(max(point.x, local.minX), local.maxX), y: min(max(point.y, local.minY), local.maxY))
    }

    private func makePanel(on screen: NSScreen) {
        displayFrame = screen.frame
        safeFrame = screen.visibleFrame
        scale = screen.backingScaleFactor
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.contentsScale = scale
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        root = view.layer
    }

    private func scheduleDismissal(after duration: UInt64) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}
