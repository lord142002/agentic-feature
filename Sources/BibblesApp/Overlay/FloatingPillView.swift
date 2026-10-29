import AppKit
import SwiftUI

struct FloatingPillView: View {
    @ObservedObject var model: InteractionModel
    @ObservedObject var meter: VoiceActivityMeter
    @ObservedObject var voiceReply: VoiceReplyController
    let onOpenChat: () -> Void
    let onClose: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onUseTranscriptAnyway: () -> Void
    let onToggleVoice: (String) -> Void
    let onInsert: (String) -> Void

    var body: some View {
        Group {
            if let answer = model.state.answerText {
                answerCard(answer)
            } else if let failure = model.state.failureText {
                failureCard(failure)
            } else {
                statusPill
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.state.headline)
    }

    private var statusPill: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(BibblesStyle.brandBackground)
                if isListening {
                    VoiceActivityView(meter: meter, mode: .listening)
                } else if model.state == .idle {
                    VoiceActivityView(meter: meter, mode: .idle)
                } else if model.state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BibblesStyle.accent)
                } else if model.state.failureText != nil {
                    VoiceActivityView(meter: meter, mode: .disabled)
                } else {
                    Image(systemName: model.state.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(BibblesStyle.accent)
                }
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.state.headline)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                if let detail = model.state.supportingText {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(BibblesStyle.muted)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 390, alignment: .leading)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(BibblesStyle.hairline, lineWidth: 0.7))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 9)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Listening, dictating or showing what you said.
    private var showsSpeechService: Bool {
        switch model.state {
        case .listening, .dictating, .transcript: return true
        default: return false
        }
    }

    private var isListening: Bool {
        guard meter.isActive else { return false }
        if case .listening = model.state { return true }
        if case .dictating = model.state { return true }
        if case .transcript(_, let isFinal) = model.state { return !isFinal }
        return false
    }

    private func answerCard(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Click and hold anywhere on the card to move it")
                BibblesBrandMark(size: 28)
                Text("Bibbles answered")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if ClaudeAPI.showsModelOnAnswers, let label = model.modelLabel {
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                        .help(label == "Deep Task" ? "Answered with deep analysis" : "Answered quickly")
                }
                Spacer()
                if model.canCancel {
                    Button("Cancel", action: onCancel)
                        .help("Stop generating this response")
                }
                Button(action: { copy(PlainText.clean(answer, forAppBundleID: nil)) }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy full answer")
                Button(action: { onInsert(answer) }) {
                    Label("Insert", systemImage: "text.cursor")
                }
                .help("Type this answer into the app you were using")
                Button(action: { onToggleVoice(answer) }) {
                    Label(voiceReply.isActive ? "Stop" : "Listen", systemImage: voiceReply.isActive ? "stop.fill" : "speaker.wave.2.fill")
                }
                .help(voiceReply.isActive ? "Stop spoken answer" : "Read the answer aloud")
                Button(action: onOpenChat) {
                    Label("Continue in Chat", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Continue this conversation in the full chat (Control + Command + A)")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .help("Close (Escape)")
            }
            .buttonStyle(.borderless)
            // The whole card can be dragged (see DraggableCardPanel).

            Divider()

            StreamingAnswerView(text: PlainText.clean(answer, forAppBundleID: nil))
            .frame(width: 500)

            if let error = voiceReply.errorMessage {
                Text(error).foregroundStyle(.orange)
                    .font(.system(size: 11))
            }
            // Which AI model answered stays private; only the status shows.
            Text(model.canCancel ? "Writing…" : (voiceReply.isActive ? "Speaking…" : "Copy, insert, listen, or continue in chat"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(BibblesStyle.hairline, lineWidth: 0.7))
        .shadow(color: .black.opacity(0.17), radius: 24, y: 10)
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if message.localizedCaseInsensitiveContains("microphone") {
                    VoiceActivityView(meter: meter, mode: .disabled)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                }
                Text("Bibbles needs attention")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: { copy(message) }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the full message")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .help("Close (Escape)")
            }
            .buttonStyle(.borderless)

            Divider()

            ScrollView {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 500)
            .frame(minHeight: 70, maxHeight: 260)

            if let recoveryText = model.recoveryText {
                HStack {
                    Text("Final dictation is ready to copy")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Final Text") { copy(recoveryText) }
                        .buttonStyle(.borderedProminent)
                }
            }

            if model.canRetry || model.canUseTranscriptAnyway {
                HStack {
                    if model.canRetry {
                        Button("Retry", action: onRetry)
                    }
                    if model.canUseTranscriptAnyway {
                        Button("Use transcript anyway", action: onUseTranscriptAnyway)
                    }
                    Spacer()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Scroll to read the complete message")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.red.opacity(0.4), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.17), radius: 24, y: 10)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Lets the user drag a borderless Bibbles panel by this area. Buttons
/// placed on top keep working.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
