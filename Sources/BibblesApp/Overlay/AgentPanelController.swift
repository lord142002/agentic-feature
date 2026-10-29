#if BIBBLES_DEVELOPER
import AppKit
import SwiftUI

/// The Files agent's card: preview with Start / Cancel, progress with Stop,
/// then Done · Undo. Developer builds only.
@MainActor
final class AgentPanelController {
    static let size = NSSize(width: 440, height: 400)
    private let panel: NSPanel
    private(set) var session: FilesAgentSession?

    init() {
        panel = DraggableCardPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = true
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ session: FilesAgentSession) {
        if let previous = self.session, previous !== session, previous.phase != .done { previous.cancel() }
        self.session = session
        panel.contentView = NSHostingView(rootView: AgentCardView(session: session, onClose: { [weak self] in self?.close() }))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (frame.midX - Self.size.width / 2).rounded(),
                                         y: (frame.maxY - Self.size.height - 24).rounded()))
        }
        panel.orderFrontRegardless()
    }

    /// The Screen agent's card (same panel), top right so it doesn't cover the form.
    func show(_ session: ScreenAgentSession) {
        self.screenSession = session
        panel.contentView = NSHostingView(rootView: ScreenAgentCardView(session: session, onClose: { [weak self] in
            if [.looking, .planning, .preview].contains(session.phase) { session.cancel() }
            self?.panel.orderOut(nil)
        }))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (frame.maxX - Self.size.width - 24).rounded(),
                                         y: (frame.maxY - Self.size.height - 24).rounded()))
        }
        panel.orderFrontRegardless()
    }

    private(set) var screenSession: ScreenAgentSession?

    /// Closing before Start cancels; after Start the run keeps its Undo in task history.
    func close() {
        if let session, [.scanning, .planning, .preview].contains(session.phase) { session.cancel() }
        panel.orderOut(nil)
    }
}

private struct AgentCardView: View {
    @ObservedObject var session: FilesAgentSession
    let onClose: () -> Void
    @State private var showList = false

    private var strings: FilesAgentStrings { session.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(BibblesStyle.accent)
                Text(strings.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if LocalMode.isOn {
                    Text("LOCAL MODE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings.close)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: AgentPanelController.size.width, height: AgentPanelController.size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.07, green: 0.075, blue: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
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
                    Text(session.progressText).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView()
                }
                HStack {
                    Spacer()
                    button(strings.stop, prominent: false) { session.stop() }
                        .disabled(session.phase == .stopping)
                }
            }
        case .done:
            VStack(alignment: .leading, spacing: 14) {
                Label(session.resultSummary, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if session.undoAvailable {
                        button(strings.undo, prominent: false) { session.undo() }
                    }
                    button(strings.close, prominent: true, action: onClose)
                }
            }
        case .undoing:
            working(strings.undo + "…")
        case .undone:
            VStack(alignment: .leading, spacing: 14) {
                Label(strings.undone, systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                HStack { Spacer(); button(strings.close, prominent: true, action: onClose) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); button(strings.close, prominent: true, action: onClose) }
            }
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.planSummary.isEmpty {
                Text(session.planSummary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(strings.previewLine(session.preview))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
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
                                        .foregroundStyle(line.isTrash ? Color.red.opacity(0.9) : .white.opacity(0.5))
                                }
                                .font(.system(size: 11.5))
                                .foregroundStyle(line.isTrash ? Color(red: 1, green: 0.55, blue: 0.5) : .white.opacity(0.85))
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                } label: {
                    Text("\(session.preview.lines.count)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            if !session.preview.dropped.isEmpty {
                Text(session.preview.dropped.map { "Step \($0.index + 1) not used: \($0.reason)" }.joined(separator: "\n"))
                    .font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                button(session.preview.isEmpty ? strings.close : strings.cancel, prominent: false) {
                    session.cancel()
                    onClose()
                }
                if !session.preview.isEmpty {
                    button(strings.start, prominent: true) { session.confirm() }
                }
            }
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.92))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? Color.white : Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(prominent ? 0 : 0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
/// Preview of the screen steps with Start / Cancel, progress with Stop, then Done · Undo.
private struct ScreenAgentCardView: View {
    @ObservedObject var session: ScreenAgentSession
    let onClose: () -> Void

    private var strings: FilesAgentStrings { session.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2").foregroundStyle(BibblesStyle.accent)
                Text(strings.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                if session.madeOnMac {
                    Text("ON THIS MAC · NO AI")
                        .font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.52, green: 0.88, blue: 0.72)))
                } else if LocalMode.isOn {
                    Text("LOCAL MODE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings.close)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: AgentPanelController.size.width, height: AgentPanelController.size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.07, green: 0.075, blue: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .looking:
            working("Looking at the app…")
        case .planning:
            working(strings.planning)
        case .preview:
            previewContent
        case .running, .stopping:
            VStack(alignment: .leading, spacing: 10) {
                if case let .running(done, total) = session.phase {
                    ProgressView(value: Double(done), total: Double(max(1, total)))
                    Text(session.progressText).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView()
                }
                HStack { Spacer(); cardButton(strings.stop, prominent: false) { session.stop() } }
            }
        case .done:
            VStack(alignment: .leading, spacing: 14) {
                Label(session.resultSummary, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if session.undoAvailable { cardButton(strings.undo, prominent: false) { session.undo() } }
                    cardButton(strings.close, prominent: true, action: onClose)
                }
            }
        case .undoing:
            working(strings.undo + "…")
        case .undone:
            VStack(alignment: .leading, spacing: 14) {
                Label("Undone. Typed fields and dark mode are back as they were.", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); cardButton(strings.close, prominent: true, action: onClose) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color(red: 1, green: 0.72, blue: 0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); cardButton(strings.close, prominent: true, action: onClose) }
            }
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.planSummary.isEmpty {
                Text(session.planSummary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.preview.isEmpty {
                Text("Nothing Bibbles can do safely here.").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.preview.lines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(line.id + 1).").foregroundStyle(.white.opacity(0.5))
                                Text(line.text).foregroundStyle(.white.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                if !line.undoable {
                                    Text("no undo").font(.system(size: 10)).foregroundStyle(Color.orange.opacity(0.8))
                                }
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
            if !session.preview.dropped.isEmpty {
                Text(session.preview.dropped.map { "Skipped: \($0.reason)" }.joined(separator: "\n"))
                    .font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                cardButton(session.preview.isEmpty ? strings.close : strings.cancel, prominent: false) {
                    session.cancel()
                    onClose()
                }
                if !session.preview.isEmpty {
                    cardButton(strings.start, prominent: true) { session.confirm() }
                }
            }
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func cardButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.92))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(prominent ? Color.white : Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(prominent ? 0 : 0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
#endif
