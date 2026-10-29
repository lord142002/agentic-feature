import AppKit
import SwiftUI

@MainActor
final class ExplanationPlayback: ObservableObject {
    @Published private(set) var lesson: VisualExplanation?
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    @Published private(set) var status: String?
    @Published private(set) var revision = UUID()
    var onStep: ((Int) -> Bool)?
    private var task: Task<Void, Never>?
    private var guidanceInvalidated = false
    var hasScreenGuidance: Bool { onStep != nil }

    @discardableResult
    func load(_ lesson: VisualExplanation) -> Bool {
        guard lesson.isValid else { return false }
        stop()
        onStep = nil
        self.lesson = lesson
        index = 0
        status = nil
        guidanceInvalidated = false
        revision = UUID()
        return true
    }

    func move(to index: Int) {
        guard let lesson, lesson.steps.indices.contains(index) else { return }
        self.index = index
        revision = UUID()
        if guidanceInvalidated || onStep?(index) == false {
            stop()
            status = "The screen context has expired. Ask again to refresh the pointer guidance."
        }
    }

    func replay() {
        stop()
        move(to: 0)
    }

    func togglePlayback() {
        if playing { stop(); return }
        guard let lesson, index < lesson.steps.count - 1 else { replay(); return }
        playing = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, self.playing, let lesson = self.lesson else { return }
                if self.index + 1 < lesson.steps.count { self.move(to: self.index + 1) }
                if self.index == lesson.steps.count - 1 { self.stop(); return }
            }
        }
    }

    func stop() { task?.cancel(); task = nil; playing = false }
    func dismiss() { stop(); onStep = nil; lesson = nil; status = nil }
    func invalidateScreenContext() {
        guard hasScreenGuidance else { return }
        guidanceInvalidated = true
        stop()
        status = "The screen changed. Tap the button below so Bibbles can look at the new screen."
    }
}

@MainActor
final class VisualExplanationController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    let player = ExplanationPlayback()
    private let onClose: () -> Void
    private let onVisibilityChanged: () -> Void
    var isVisible: Bool { panel.isVisible }

    init(onClose: @escaping () -> Void, onVisibilityChanged: @escaping () -> Void) {
        self.onClose = onClose
        self.onVisibilityChanged = onVisibilityChanged
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 550, height: 650),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "Bibbles · Explain visually"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 440, height: 540)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(_ lesson: VisualExplanation, provenance: String, avoiding target: CGRect? = nil,
              onStep: ((Int) -> Bool)? = nil, onRefresh: (() -> Void)? = nil,
              refreshTitle: String = "Refresh screen") {
        guard player.load(lesson) else { return }
        player.onStep = onStep
        panel.contentView = NSHostingView(rootView: VisualExplanationView(player: player, provenance: provenance, onClose: onClose, onRefresh: onRefresh, refreshTitle: refreshTitle))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let safe = screen?.visibleFrame {
            let size = NSSize(width: min(550, safe.width - 24), height: min(650, safe.height - 24))
            var frame = NSRect(x: safe.maxX - size.width - 12, y: safe.midY - size.height / 2, width: size.width, height: size.height)
            if let target, frame.intersects(target) { frame.origin.x = safe.minX + 12 }
            panel.setFrame(frame, display: true)
        }
        player.move(to: 0)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChanged()
    }

    func hide() {
        player.dismiss()
        panel.orderOut(nil)
        onVisibilityChanged()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { onClose(); return false }
}

struct VisualExplanationView: View {
    @ObservedObject var player: ExplanationPlayback
    let provenance: String
    let onClose: () -> Void
    var onRefresh: (() -> Void)? = nil
    var refreshTitle = "Refresh screen"
    var animationsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                BibblesBrandMark(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.lesson?.title ?? "Visual explanation").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(provenance).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close and stop · Escape")
            }
            if let lesson = player.lesson, lesson.steps.indices.contains(player.index) {
                let step = lesson.steps[player.index]
                HStack(spacing: 5) {
                    ForEach(lesson.steps.indices, id: \.self) { index in
                        Capsule().fill(index <= player.index ? BibblesStyle.accent : Color.secondary.opacity(0.15)).frame(height: 3)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(player.index + 1) / \(lesson.steps.count)  ·  \(step.title)").font(.headline)
                        if !step.strokes.isEmpty || !step.labels.isEmpty {
                            ExplanationCanvas(step: step, animationsEnabled: animationsEnabled).id(player.revision)
                                .frame(height: 235)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
                                .accessibilityLabel("Diagram. " + step.labels.map(\.text).joined(separator: ", "))
                        }
                        Text(step.explanation).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                        if let status = player.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                        if let onRefresh {
                            Button(action: onRefresh) { Label(refreshTitle, systemImage: "arrow.clockwise") }
                                .buttonStyle(.bordered)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button { player.stop(); player.move(to: player.index - 1) } label: { Image(systemName: "chevron.left") }.disabled(player.index == 0).help("Previous step")
                    Button { player.togglePlayback() } label: { Label(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill") }
                    Button { player.replay() } label: { Image(systemName: "arrow.counterclockwise") }.help("Replay")
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lesson.transcript, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.help("Copy explanation")
                    Button("Next") { player.stop(); player.move(to: player.index + 1) }
                        .buttonStyle(.borderedProminent).disabled(player.index == lesson.steps.count - 1)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(22).padding(.top, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(BibblesStyle.accent)
        .onExitCommand(perform: onClose)
    }
}

private struct ExplanationCanvas: View {
    let step: VisualExplanationStep
    let animationsEnabled: Bool
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let offset = CGPoint(x: (geometry.size.width - side) / 2, y: (geometry.size.height - side) / 2)
            ZStack {
                ForEach(0..<step.strokes.count, id: \.self) { index in
                    let stroke = step.strokes[index]
                    Path { path in
                        for (ordinal, point) in stroke.points.enumerated() {
                            let mapped = CGPoint(x: offset.x + point.x * side, y: offset.y + point.y * side)
                            if ordinal == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
                        }
                    }
                    .trim(from: 0, to: reduceMotion || !animationsEnabled ? 1 : progress)
                    .stroke(color(stroke.tone), style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
                }
                ForEach(0..<step.labels.count, id: \.self) { index in
                    let label = step.labels[index]
                    let x: CGFloat = min(max(offset.x + CGFloat(label.position.x) * side, 75), geometry.size.width - 75)
                    let y: CGFloat = offset.y + CGFloat(label.position.y) * side
                    ExplanationCanvasLabel(text: label.text)
                        .position(x: x, y: y)
                        .opacity(reduceMotion || !animationsEnabled ? 1 : Double(progress))
                }
            }
        }
        .clipped()
        .onAppear {
            if reduceMotion || !animationsEnabled { progress = 1 }
            else { withAnimation(.easeInOut(duration: 0.55)) { progress = 1 } }
        }
    }

    private func color(_ tone: String) -> Color {
        switch tone {
        case "violet": return .purple
        case "coral": return .orange
        case "amber": return Color(red: 0.75, green: 0.48, blue: 0.04)
        default: return .teal
        }
    }
}

private struct ExplanationCanvasLabel: View {
    let text: String
    var body: some View {
        let width: CGFloat = min(140, CGFloat(text.count) * 7 + 8)
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .padding(5)
            .background(.regularMaterial, in: Capsule())
    }
}
