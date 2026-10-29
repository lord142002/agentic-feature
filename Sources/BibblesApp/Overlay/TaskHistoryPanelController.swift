import AppKit
import SwiftUI

/// One finished task: what the user asked and what Bibbles did.
struct TaskHistoryItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case ask, screen, search, action, fix, write

        var symbol: String {
            switch self {
            case .ask: return "sparkles"
            case .screen: return "viewfinder"
            case .search: return "globe"
            case .action: return "bolt.fill"
            case .fix: return "wrench.and.screwdriver.fill"
            case .write: return "square.and.pencil"
            }
        }

        var label: String {
            switch self {
            case .ask: return "Answer"
            case .screen: return "Screen help"
            case .search: return "Web search"
            case .action: return "Mac action"
            case .fix: return "Fix"
            case .write: return "Writing"
            }
        }

        /// One clear colour per kind for the row's symbol.
        var tint: Color {
            switch self {
            case .ask: return Color(red: 1.0, green: 0.58, blue: 0.45)      // coral
            case .screen: return Color(red: 0.45, green: 0.75, blue: 1.0)   // sky blue
            case .search: return Color(red: 0.38, green: 0.86, blue: 0.82)  // teal
            case .action: return Color(red: 1.0, green: 0.74, blue: 0.38)   // amber
            case .fix: return Color(red: 0.96, green: 0.45, blue: 0.72)     // pink
            case .write: return Color(red: 0.45, green: 0.88, blue: 0.6)    // mint
            }
        }

        /// Two brand colours per kind, so rows are easy to tell apart.
        var colors: [Color] {
            switch self {
            case .ask: return [Color(red: 0.765, green: 0.714, blue: 1.0), Color(red: 0.541, green: 0.459, blue: 0.957)]
            case .screen: return [Color(red: 0.557, green: 0.663, blue: 1.0), Color(red: 0.373, green: 0.290, blue: 0.839)]
            case .search: return [Color(red: 0.463, green: 0.851, blue: 0.894), Color(red: 0.302, green: 0.522, blue: 0.957)]
            case .action: return [Color(red: 1.0, green: 0.776, blue: 0.443), Color(red: 0.957, green: 0.533, blue: 0.369)]
            case .fix: return [Color(red: 0.996, green: 0.588, blue: 0.616), Color(red: 0.851, green: 0.369, blue: 0.588)]
            case .write: return [Color(red: 0.525, green: 0.918, blue: 0.667), Color(red: 0.239, green: 0.698, blue: 0.592)]
            }
        }
    }

    let id: UUID
    let conversationID: UUID
    let question: String
    let answer: String
    let date: Date
    let kind: Kind
    let questionPreview: String
    let answerPreview: String

    init(id: UUID, conversationID: UUID, question: String, answer: String, date: Date, kind: Kind) {
        self.id = id
        self.conversationID = conversationID
        self.question = question
        self.answer = answer
        self.date = date
        self.kind = kind
        // One-line display strings never need to process a whole long answer during hover.
        questionPreview = TaskHistory.preview(String(question.prefix(512)))
        answerPreview = TaskHistory.preview(String(answer.prefix(512)))
    }
}

enum TaskHistory {
    /// Every question and its answer across saved conversations, newest first.
    static func items(from conversations: [ChatConversation], limit: Int = 60) -> [TaskHistoryItem] {
        var candidates: [(id: UUID, conversationID: UUID, question: String, answer: String, date: Date, sources: Bool)] = []
        for conversation in conversations.prefix(80) {
            guard !Task.isCancelled else { return [] }
            let messages = conversation.messages
            for (index, message) in messages.enumerated() where message.role == .user {
                guard !Task.isCancelled else { return [] }
                guard index + 1 < messages.count else { continue }
                let reply = messages[index + 1]
                let answer = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard reply.role == .assistant, !answer.isEmpty else { continue }
                let question = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                candidates.append((
                    id: message.id,
                    conversationID: conversation.id,
                    question: question.isEmpty ? "Task" : question,
                    answer: answer,
                    date: reply.createdAt,
                    sources: reply.sources?.isEmpty == false
                ))
            }
        }
        // Classify and format only the rows we will actually display.
        return candidates.sorted { $0.date > $1.date }.prefix(max(0, limit)).map {
            TaskHistoryItem(id: $0.id, conversationID: $0.conversationID, question: $0.question,
                            answer: $0.answer, date: $0.date,
                            kind: kind(question: $0.question, hasSources: $0.sources))
        }
    }

    static func kind(question: String, hasSources: Bool) -> TaskHistoryItem.Kind {
        if hasSources { return .search }
        let router = IntentRouter()
        if router.isFixRequest(question) { return .fix }
        if router.isWriteRequest(question) || router.isFillRequest(question) { return .write }
        if router.isCommandRequest(question) { return .action }
        if IntentRouter.isLocateRequest(question) || IntentRouter.refersToScreenContent(question) { return .screen }
        let lower = question.lowercased()
        if ["search the web", "search for", "google", "latest news", "look up"].contains(where: lower.contains) { return .search }
        return .ask
    }

    /// "2:14 PM" today, "Yesterday", a weekday this week, otherwise "26 Sep 2026".
    static func timeLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return formatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// Does this sound like it continues the previous task ("and the
    /// other one?", "explain more", "aur batao") rather than a new one?
    static func isFollowUp(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let starts = ["and ", "also ", "now ", "then ", "what about", "how about", "explain more", "tell me more",
                      "more about", "continue", "go on", "again", "same ", "do the same", "do it", "that one",
                      "this one", "the other", "next one", "make it", "change it", "shorter", "longer",
                      "aur ", "phir ", "isko", "usko", "iske", "uske", "aage", "aur batao"]
        if starts.contains(where: { lower.hasPrefix($0) }) { return true }
        return ["explain more", "tell me more", "continue", "go on", "aur batao", "and?", "why?"].contains(lower)
    }

    /// A one-line preview without Markdown symbols or line breaks.
    static func preview(_ text: String) -> String {
        text.replacingOccurrences(of: #"[`*_#>]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Builds only after a persisted chat change, away from pointer/layout work.
/// Account changes clear immediately and invalidate any older calculation.
@MainActor
final class TaskHistorySnapshot: ObservableObject {
    @Published private(set) var items: [TaskHistoryItem] = []
    private var revision: UInt64 = 0
    private var pending: Task<Void, Never>?

    @discardableResult
    func update(from conversations: [ChatConversation]) -> Task<Void, Never> {
        revision &+= 1
        let current = revision
        pending?.cancel()
        let calculation = Task.detached(priority: .utility) { TaskHistory.items(from: conversations) }
        let task = Task { [weak self] in
            let result = await withTaskCancellationHandler(operation: { await calculation.value },
                                                          onCancel: { calculation.cancel() })
            guard !Task.isCancelled, let self, self.revision == current else { return }
            if self.items != result { self.items = result }
            self.pending = nil
        }
        pending = task
        return task
    }

    func clear() {
        revision &+= 1
        pending?.cancel()
        pending = nil
        if !items.isEmpty { items = [] }
    }

    deinit { pending?.cancel() }
}

/// A dark panel that drops down from the notch when the pointer reaches the
/// top centre of the screen, listing the tasks Bibbles has finished.
@MainActor
final class TaskHistoryPanelController {
    static let width: CGFloat = 460
    private let panel: NSPanel
    private let history: TaskHistorySnapshot
    private let pointerIsNearNotch: () -> Bool
    private let onVisibilityChanged: () -> Void
    private var watchTimer: Timer?
    private var leftAt: Date?
    private var presentationGeneration: UInt64 = 0
    private var presented = false

    init(
        store: ChatConversationStore,
        pointerIsNearNotch: @escaping () -> Bool,
        onOpenItem: @escaping (TaskHistoryItem) -> Void,
        onOpenChat: @escaping () -> Void,
        onNewChat: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onShowHelp: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onVisibilityChanged: @escaping () -> Void
    ) {
        self.history = store.taskHistory
        self.pointerIsNearNotch = pointerIsNearNotch
        self.onVisibilityChanged = onVisibilityChanged
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Same layer and Spaces as the notch bar, so it also opens over
        // full-screen apps.
        panel.level = NotchGeometry.overlayLevel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = NotchGeometry.everySpace
        // The closures are wrapped so a click first tucks the panel away.
        var hideSelf: () -> Void = {}
        panel.contentView = NotchHostingView(rootView: TaskHistoryView(
            history: store.taskHistory,
            onOpenItem: { item in hideSelf(); onOpenItem(item) },
            onOpenChat: { hideSelf(); onOpenChat() },
            onNewChat: { hideSelf(); onNewChat() },
            onOpenSettings: { hideSelf(); onOpenSettings() },
            onShowHelp: { hideSelf(); onShowHelp() },
            onQuit: onQuit
        ))
        hideSelf = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { presented && panel.isVisible }

    /// Shows the panel just below `anchor` (the Bibbles bar around the
    /// notch), or below the top centre of the pointer's screen.
    func showBelowNotch(anchor: CGRect? = nil) {
        let point = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let count = history.items.count
        // Header + footer + one row per task, between a compact and a tall panel.
        let height = min(max(150 + CGFloat(count) * 80, count == 0 ? 250 : 240), min(620, screen.visibleFrame.height - 40))
        let topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let top = anchor.map { $0.minY } ?? (screen.frame.maxY - topInset)
        let centerX = anchor?.midX ?? screen.frame.midX
        let target = NSRect(
            x: (centerX - Self.width / 2).rounded(),
            y: (top - 6 - height).rounded(),
            width: Self.width,
            height: height
        )
        leftAt = nil
        presentationGeneration &+= 1
        presented = true
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible || watchTimer == nil {
            panel.alphaValue = animate ? 0 : 1
            // Lay out once: resizing the hosting window every animation frame stalls scrolling.
            panel.setFrame(target, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animate ? 0.12 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 1
            }
        } else {
            panel.animator().alphaValue = 1
            panel.setFrame(target, display: true)
        }
        startWatchingPointer()
        onVisibilityChanged()
    }

    func hide() {
        presentationGeneration &+= 1
        presented = false
        let generation = presentationGeneration
        watchTimer?.invalidate()
        watchTimer = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.10
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Re-shown during the fade: keep it.
                guard self.presentationGeneration == generation, self.watchTimer == nil else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.onVisibilityChanged()
            }
        })
    }

    /// Space changes must remove this panel before the next frame.
    func hideImmediately() {
        presentationGeneration &+= 1
        presented = false
        watchTimer?.invalidate()
        watchTimer = nil
        leftAt = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
        onVisibilityChanged()
    }

    /// Tucks the panel away shortly after the pointer leaves both the panel
    /// and the notch area.
    private func startWatchingPointer() {
        watchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func checkPointer() {
        guard panel.isVisible else { return }
        let inside = panel.frame.insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation) || pointerIsNearNotch()
        if inside {
            leftAt = nil
        } else if let leftAt {
            if Date().timeIntervalSince(leftAt) > 0.22 { hide() }
        } else {
            leftAt = Date()
        }
    }
}

/// Colours for the task panel: deep night, soft hairlines, rainbow accent.
private enum TaskTheme {
    static let background = Color(red: 0.043, green: 0.047, blue: 0.067)
    static let line = Color.white.opacity(0.08)
    static let rowHighlight = Color.white.opacity(0.05)
    static let rainbowColors: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 1.0),
        Color(red: 0.66, green: 0.55, blue: 1.0),
        Color(red: 0.98, green: 0.58, blue: 0.86),
        Color(red: 1.0, green: 0.82, blue: 0.50),
        Color(red: 0.58, green: 0.95, blue: 0.74)
    ]
    static let rainbow = LinearGradient(colors: rainbowColors, startPoint: .leading, endPoint: .trailing)
    static let rainbowDown = LinearGradient(colors: [rainbowColors[2], rainbowColors[1], rainbowColors[0], rainbowColors[4]],
                                            startPoint: .top, endPoint: .bottom)
}

private struct TaskHistoryView: View {
    @ObservedObject var history: TaskHistorySnapshot
    let onOpenItem: (TaskHistoryItem) -> Void
    let onOpenChat: () -> Void
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void
    let onShowHelp: () -> Void
    let onQuit: () -> Void
    @State private var hovered: UUID?

    private var items: [TaskHistoryItem] { history.items }

    var body: some View {
        let list = self.items
        VStack(spacing: 0) {
            header(count: list.count)
            Rectangle().fill(TaskTheme.line).frame(height: 1).padding(.horizontal, 16)
            if list.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { item in
                            row(item, highlighted: hovered == item.id || (hovered == nil && item.id == list.first?.id))
                            if item.id != list.last?.id {
                                Rectangle().fill(TaskTheme.line).frame(height: 1).padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Spacer(minLength: 0)
            Rectangle().fill(TaskTheme.line).frame(height: 1).padding(.horizontal, 16)
            footer
        }
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(TaskTheme.background))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 12) {
            BibblesBrandMark(size: 30)
            Text("Task history")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.09), in: Capsule())
            }
            Spacer()
            HStack(spacing: 6) {
                headerButton("power", "Quit Bibbles", onQuit)
                headerButton("info.circle", "Getting started", onShowHelp)
                headerButton("slider.horizontal.3", "Settings", onOpenSettings)
                headerButton("arrow.up.left.and.arrow.down.right", "Open chat", onOpenChat)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private func headerButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// A simple outline icon for what the task was.
    private static func symbol(for item: TaskHistoryItem) -> String {
        let text = item.question.lowercased()
        func has(_ words: [String]) -> Bool { words.contains(where: text.contains) }
        if has(["chart", "candle", "support", "resistance", "price"]) { return "chart.bar.xaxis" }
        if has(["calendar", "meeting", "event", "remind"]) { return "calendar" }
        switch item.kind {
        case .action: return has(["folder"]) ? "folder.badge.plus" : "bolt"
        case .screen: return has(["folder", "file"]) ? "folder" : "display"
        case .search: return "globe"
        case .fix: return "doc.text"
        case .write: return "square.and.pencil"
        case .ask:
            if has(["screen"]) { return "display" }
            if has(["listening", "hear me", "can you hear"]) { return "mic" }
            return "bubble.left"
        }
    }

    private func row(_ item: TaskHistoryItem, highlighted: Bool) -> some View {
        Button { onOpenItem(item) } label: {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: Self.symbol(for: item))
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.questionPreview)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(TaskHistory.timeLabel(for: item.date))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize()
                    }
                    Text(item.answerPreview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(highlighted ? TaskTheme.rowHighlight : .clear)
                    .padding(.horizontal, 6)
            )
            .overlay(alignment: .leading) {
                if highlighted {
                    Capsule().fill(TaskTheme.rainbowDown).frame(width: 3).padding(.vertical, 8).padding(.leading, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        .help("\(item.kind.label) · open in chat")
        .accessibilityLabel("\(item.kind.label): \(item.question)")
        .contextMenu {
            Button("Open in Chat") { onOpenItem(item) }
            Button("Copy Answer") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PlainText.clean(item.answer, forAppBundleID: nil), forType: .string)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("No tasks yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("Hold ⌃⌥ and ask anything. Finished tasks show up here.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onNewChat) {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.pencil").font(.system(size: 15))
                    Text("New chat").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    // A glowing rainbow edge along the top of the button.
                    TaskTheme.rainbow
                        .frame(height: 1.5)
                        .padding(.horizontal, 12)
                        .shadow(color: TaskTheme.rainbowColors[1].opacity(0.8), radius: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: 5) {
                keyCap("⌃")
                keyCap("⌥")
            }
            Text("Hold to ask")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}
