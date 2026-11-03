#if BIBBLES_DEVELOPER
import AppKit
import SwiftUI

/// The agent card (Files or Screen agent), styled like Bibbles' answer card.
/// It no longer opens by itself: clicking the agent robot opens it right
/// under the robot (the robot shows a red 1 when the agent needs you).
/// Developer builds only.
@MainActor
final class AgentPanelController {
    static let width: CGFloat = 440
    /// Room for the tallest card; the panel shrinks to fit what the card shows.
    static let maxHeight: CGFloat = 560
    private let panel: NSPanel
    private(set) var session: FilesAgentSession?
    private(set) var screenSession: ScreenAgentSession?
    /// The card's height right now (it changes with what the agent shows).
    private var cardHeight: CGFloat = 200

    init() {
        panel = DraggableCardPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: 200)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = true
    }

    var isVisible: Bool { panel.isVisible }

    /// A new Files agent task: the card is ready, but opens only from the robot.
    func attach(_ session: FilesAgentSession) {
        if let previous = self.session, previous !== session, previous.phase != .done { previous.cancel() }
        self.session = session
        screenSession = nil
        setContent(AgentCardView(session: session, onClose: { [weak self] in self?.close() }))
    }

    /// A new Screen agent task: the card is ready, but opens only from the robot.
    func attach(_ session: ScreenAgentSession) {
        screenSession = session
        self.session = nil
        setContent(ScreenAgentCardView(session: session, onClose: { [weak self] in self?.close() }))
    }

    /// Opens the card now (task history, Undo).
    func show(_ session: FilesAgentSession) {
        attach(session)
        present()
    }

    /// Clicking the robot: open or close the card.
    func toggle() {
        if panel.isVisible { close() } else { present() }
    }

    func present() {
        guard session != nil || screenSession != nil else { return }
        place()
        panel.orderFrontRegardless()
    }

    /// Close: before Start it cancels (a question waiting for an OK is answered no);
    /// a running task keeps going, with the robot in the corner.
    func close() {
        var stillWorking = false
        if let session {
            if [.scanning, .planning, .preview].contains(session.phase) { session.cancel() }
            stillWorking = [.stopping, .undoing].contains(session.phase) || { if case .running = session.phase { return true } else { return false } }()
        }
        if let screenSession {
            if screenSession.pendingConfirmation != nil { screenSession.answerConfirmation(false) }
            if [.looking, .planning, .preview].contains(screenSession.phase) { screenSession.cancel() }
            stillWorking = [.stopping, .undoing].contains(screenSession.phase)
                || { if case .running = screenSession.phase { return true } else { return false } }()
        }
        panel.orderOut(nil)
        AgentRobotController.shared.cardClosed(stillWorking: stillWorking)
    }

    private func setContent<Content: View>(_ card: Content) {
        let root = card
            .background(GeometryReader { proxy in
                Color.clear.preference(key: AgentCardHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(AgentCardHeightKey.self) { [weak self] height in
                Task { @MainActor in self?.resize(to: height) }
            }
            .frame(width: Self.width, alignment: .top)
        panel.contentView = NSHostingView(rootView: root)
    }

    /// Fits the panel to the card, keeping its top edge where it is.
    private func resize(to height: CGFloat) {
        let height = min(Self.maxHeight, max(80, height.rounded(.up)))
        guard abs(height - cardHeight) > 0.5 || panel.frame.height != height else { return }
        cardHeight = height
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height), display: true)
    }

    /// Right under the robot (top right), or the top-right corner when it's not there.
    private func place() {
        let height = cardHeight
        if let robot = AgentRobotController.shared.frame, AgentRobotController.shared.isVisible {
            panel.setFrame(NSRect(x: (robot.maxX - Self.width).rounded(), y: (robot.minY - 6 - height).rounded(),
                                  width: Self.width, height: height), display: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: (frame.maxX - Self.width - AgentRobotController.margin).rounded(),
                              y: (frame.maxY - AgentRobotController.margin - height).rounded(),
                              width: Self.width, height: height), display: true)
    }
}

private struct AgentCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The header and frame every agent card shares, matching Bibbles' answer card:
/// the Bibbles mark, a title, a chip, a close button, a divider, frosted glass.
private struct AgentCardChrome<Content: View>: View {
    let chip: String
    let chipTint: Color?
    let closeLabel: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Click and hold anywhere on the card to move it")
                BibblesBrandMark(size: 28)
                Text("Bibbles agent")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(chip)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(chipTint == nil ? Color.primary.opacity(0.85) : Color.black)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(chipTint ?? Color.primary.opacity(0.1)))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel(closeLabel)
            }
            Divider()
            content
        }
        .padding(14)
        .frame(width: AgentPanelController.width, alignment: .topLeading)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(BibblesStyle.hairline, lineWidth: 0.7))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A button like Bibbles' cards: the main action in the accent colour, others quiet.
private func agentCardButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.9))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(prominent ? BibblesStyle.accentSecondary : Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.14), lineWidth: 1))
    }
    .buttonStyle(.plain)
}

private struct AgentCardView: View {
    @ObservedObject var session: FilesAgentSession
    let onClose: () -> Void
    @State private var showList = false

    private var strings: FilesAgentStrings { session.strings }

    var body: some View {
        AgentCardChrome(chip: LocalMode.isOn ? strings.label + " · LOCAL MODE" : strings.label, chipTint: nil,
                        closeLabel: strings.close, onClose: onClose) {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .scanning:
            working(strings.looking)
        case .planning:
            working(strings.planning)
        case .preview:
            previewContent
        case .running, .stopping:
            VStack(alignment: .leading, spacing: 10) {
                if case let .running(done, total) = session.phase {
                    ProgressView(value: Double(done), total: Double(max(1, total)))
                    Text(session.progressText).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.8))
                } else {
                    ProgressView()
                }
                HStack {
                    Spacer()
                    agentCardButton(strings.stop, prominent: false) { session.stop() }
                        .disabled(session.phase == .stopping)
                }
            }
        case .done:
            VStack(alignment: .leading, spacing: 14) {
                Label(session.resultSummary, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if session.undoAvailable {
                        agentCardButton(strings.undo, prominent: false) { session.undo() }
                    }
                    agentCardButton(strings.close, prominent: true, action: onClose)
                }
            }
        case .undoing:
            working(strings.undo + "…")
        case .undone:
            VStack(alignment: .leading, spacing: 14) {
                Label(strings.undone, systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                HStack { Spacer(); agentCardButton(strings.close, prominent: true, action: onClose) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); agentCardButton(strings.close, prominent: true, action: onClose) }
            }
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.planSummary.isEmpty {
                Text(session.planSummary).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(strings.previewLine(session.preview))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !session.preview.lines.isEmpty {
                DisclosureGroup(isExpanded: $showList) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(session.preview.lines) { line in
                                HStack(spacing: 6) {
                                    Image(systemName: line.isTrash ? "trash.fill" : "doc")
                                        .font(.system(size: 10))
                                    Text(line.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    Text(line.detail).lineLimit(1).truncationMode(.head)
                                        .foregroundStyle(line.isTrash ? Color.red.opacity(0.9) : Color.primary.opacity(0.5))
                                }
                                .font(.system(size: 11.5))
                                .foregroundStyle(line.isTrash ? Color.red : Color.primary.opacity(0.85))
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                } label: {
                    Text("\(session.preview.lines.count)").font(.system(size: 12)).foregroundStyle(.primary.opacity(0.6))
                }
            }
            if !session.preview.dropped.isEmpty {
                Text(session.preview.dropped.map { "Step \($0.index + 1) not used: \($0.reason)" }.joined(separator: "\n"))
                    .font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                agentCardButton(session.preview.isEmpty ? strings.close : strings.cancel, prominent: false) {
                    session.cancel()
                    onClose()
                }
                if !session.preview.isEmpty {
                    agentCardButton(strings.start, prominent: true) { session.confirm() }
                }
            }
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 13.5)).foregroundStyle(.primary.opacity(0.85))
        }
    }

}
/// Preview of the screen steps with Start / Cancel, progress with Stop, then Done · Undo.
private struct ScreenAgentCardView: View {
    @ObservedObject var session: ScreenAgentSession
    let onClose: () -> Void

    private var strings: FilesAgentStrings { session.strings }

    var body: some View {
        AgentCardChrome(chip: strings.label + (session.madeOnMac ? " · ON THIS MAC" : LocalMode.isOn ? " · LOCAL MODE" : ""),
                        chipTint: nil, closeLabel: strings.close, onClose: onClose) {
            if let ask = session.pendingConfirmation {
                confirmation(ask)
            } else {
                content
            }
        }
    }

    /// A final action (Send, Buy…) waiting for the user's OK.
    private func confirmation(_ action: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bibbles needs your OK", systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(action + "?")
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("It may not be possible to undo this. You can also say “continue” or “stop”.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                agentCardButton("Stop", prominent: false) { session.answerConfirmation(false) }
                agentCardButton("Do it", prominent: true) { session.answerConfirmation(true) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .looking, .planning:
            VStack(alignment: .leading, spacing: 12) {
                working(session.phase == .looking ? (session.round > 1 ? "Looking again…" : "Looking at the app…") : strings.planning)
                if session.round > 1 {
                    Text("Part \(session.round) · \(session.history.count) steps done").font(.system(size: 12)).foregroundStyle(.primary.opacity(0.55))
                    HStack { Spacer(); agentCardButton(strings.stop, prominent: false) { session.stop() } }
                }
            }
        case .preview:
            previewContent
        case .running, .stopping:
            VStack(alignment: .leading, spacing: 10) {
                if case let .running(done, total) = session.phase {
                    ProgressView(value: Double(done), total: Double(max(1, total)))
                    Text(session.progressText).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.8))
                } else {
                    ProgressView()
                }
                HStack { Spacer(); agentCardButton(strings.stop, prominent: false) { session.stop() } }
            }
        case .done:
            VStack(alignment: .leading, spacing: 14) {
                Label(session.resultSummary, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let file = session.savedFile {
                        agentCardButton("Show in Finder", prominent: false) {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                    }
                    Spacer()
                    if session.undoAvailable { agentCardButton(strings.undo, prominent: false) { session.undo() } }
                    agentCardButton(strings.close, prominent: true, action: onClose)
                }
            }
        case .undoing:
            working(strings.undo + "…")
        case .undone:
            VStack(alignment: .leading, spacing: 14) {
                Label("Undone. Typed fields and dark mode are back as they were.", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); agentCardButton(strings.close, prominent: true, action: onClose) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); agentCardButton(strings.close, prominent: true, action: onClose) }
            }
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.planSummary.isEmpty {
                Text((session.round > 1 ? "Part \(session.round): " : "") + session.planSummary)
                    .font(.system(size: 13)).foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.preview.isEmpty {
                Text("Nothing Bibbles can do safely here.").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.preview.lines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(line.id + 1).").foregroundStyle(.primary.opacity(0.5))
                                Text(line.text).foregroundStyle(.primary.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                if line.asksFirst {
                                    Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Color.orange)
                                } else if !line.undoable {
                                    Text("no undo").font(.system(size: 10)).foregroundStyle(Color.orange.opacity(0.8))
                                }
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
            if !session.preview.notes.isEmpty {
                Text(session.preview.notes.map { "Note: \($0)" }.joined(separator: "\n"))
                    .font(.system(size: 11)).foregroundStyle(.primary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.preview.dropped.isEmpty {
                Text(session.preview.dropped.map { "Skipped: \($0.reason)" }.joined(separator: "\n"))
                    .font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                agentCardButton(session.preview.isEmpty ? strings.close : strings.cancel, prominent: false) {
                    session.cancel()
                    onClose()
                }
                if !session.preview.isEmpty {
                    agentCardButton(session.startTitle, prominent: true) { session.confirm() }
                }
            }
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 13.5)).foregroundStyle(.primary.opacity(0.85))
        }
    }

}
#endif
