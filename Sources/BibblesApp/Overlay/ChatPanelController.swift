import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ChatPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let store: ChatConversationStore
    private var hasPositioned = false
    private let onVisibilityChanged: () -> Void

    init(
        store: ChatConversationStore,
        onDismiss: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onVisibilityChanged: @escaping () -> Void,
        onSubmit: @escaping (String, [ChatDocument], Bool) -> Bool
    ) {
        self.store = store
        self.onVisibilityChanged = onVisibilityChanged
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.title = "Bibbles"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 760, height: 560)
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Always the dark website look.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(srgbRed: 0.043, green: 0.047, blue: 0.067, alpha: 1)
        panel.contentView = NSHostingView(rootView: ChatWindowView(
            store: store,
            onDismiss: onDismiss,
            onEscape: onEscape,
            onSubmit: onSubmit
        ))
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        ProductAnalytics.shared.screen(.chat)
        store.refreshWeeklyMinutesSaved()
        if !hasPositioned {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let size = NSSize(width: min(1020, screen.width - 48), height: min(720, screen.height - 64))
            panel.setFrame(NSRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            ), display: true)
            hasPositioned = true
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChanged()
    }

    func hide() {
        ProductAnalytics.shared.leaveScreen(.chat)
        panel.orderOut(nil)
        onVisibilityChanged()
    }

    func windowWillClose(_ notification: Notification) {
        ProductAnalytics.shared.leaveScreen(.chat)
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChanged() }
    }
}

/// Colours for the chat window: deep night background, soft hairlines and a
/// rainbow accent (blue → violet → pink → amber → mint).
private enum ChatTheme {
    static let window = Color(red: 0.043, green: 0.047, blue: 0.067)
    static let sidebar = Color(red: 0.035, green: 0.039, blue: 0.055)
    static let card = Color.white.opacity(0.045)
    static let selected = Color.white.opacity(0.07)
    static let line = Color.white.opacity(0.08)
    static let text = Color.white
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.38)
    static let rainbowColors: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 1.0),
        Color(red: 0.66, green: 0.55, blue: 1.0),
        Color(red: 0.98, green: 0.58, blue: 0.86),
        Color(red: 1.0, green: 0.82, blue: 0.50),
        Color(red: 0.58, green: 0.95, blue: 0.74)
    ]
    static let rainbow = LinearGradient(colors: rainbowColors, startPoint: .leading, endPoint: .trailing)
    static let rainbowDown = LinearGradient(colors: rainbowColors, startPoint: .top, endPoint: .bottom)
    static let gradient = LinearGradient(colors: [BibblesStyle.accent, BibblesStyle.accentSecondary],
                                         startPoint: .leading, endPoint: .trailing)
}

private struct ChatWindowView: View {
    @ObservedObject var store: ChatConversationStore
    let onDismiss: () -> Void
    let onEscape: () -> Void
    let onSubmit: (String, [ChatDocument], Bool) -> Bool
    @State private var prompt = ""
    @State private var documents: [ChatDocument] = []
    @State private var searchWeb = false
    @State private var searchText = ""
    @State private var dictationHint = false
    @FocusState private var composerFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(ChatTheme.line).frame(width: 1)
            conversation
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(ChatTheme.window)
        .environment(\.colorScheme, .dark)
        .tint(BibblesStyle.accent)
        .onExitCommand(perform: onEscape)
    }

    // MARK: Sidebar

    private var filteredConversations: [ChatConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.conversations }
        return store.conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BibblesBrandMark(size: 40)
                Text("Bibbles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color(red: 0.86, green: 0.84, blue: 1.0)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                Spacer(minLength: 0)
            }
            .padding(.top, 44)
            .padding(.bottom, 26)

            Button {
                store.createConversation()
                composerFocused = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .regular))
                    Text("New conversation")
                    Spacer()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ChatTheme.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChatTheme.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("New conversation (⌘N)")

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatTheme.faint)
                TextField("Find a conversation", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(ChatTheme.text)
                    .focused($searchFocused)
                Text("⌘ K")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ChatTheme.faint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ChatTheme.line, lineWidth: 1))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChatTheme.line, lineWidth: 1))
            .padding(.top, 14)
            .background(
                // ⌘K jumps to the search box.
                Button("") { searchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            )

            Text("RECENT")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(ChatTheme.faint)
                .padding(.top, 26)
                .padding(.bottom, 10)
                .padding(.leading, 4)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredConversations) { item in
                        conversationRow(item)
                    }
                    if filteredConversations.isEmpty {
                        Text(searchText.isEmpty ? "No conversations yet" : "Nothing matches “\(searchText)”")
                            .font(.system(size: 12))
                            .foregroundStyle(ChatTheme.faint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 6)
                            .padding(.top, 6)
                    }
                }
            }

            Rectangle().fill(ChatTheme.line).frame(height: 1).padding(.top, 8)
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatTheme.rainbowDown)
                Text(String(format: "%.1f min", store.weeklyMinutesSaved))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatTheme.gradient)
                Text("saved this week")
                    .font(.system(size: 12.5))
                    .foregroundStyle(ChatTheme.dim)
            }
            .help("Estimated from dictation · stays on this Mac")
            .padding(.vertical, 14)
            Rectangle().fill(ChatTheme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 9) {
                shortcutHint(["⌃", "⌥"], "Ask about screen")
                shortcutHint(["fn", "⌃"], "Dictate anywhere")
            }
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 18)
        .frame(width: 274)
        .background(ChatTheme.sidebar)
    }

    private func conversationRow(_ item: ChatConversation) -> some View {
        let selected = item.id == store.selectedID
        return Button {
            store.selectedID = item.id
        } label: {
            HStack(spacing: 13) {
                Image(systemName: Self.symbol(for: item))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.62))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.86))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(Self.age(of: item.updatedAt))
                        .font(.system(size: 11.5))
                        .foregroundStyle(ChatTheme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? ChatTheme.selected : .clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(ChatTheme.rainbowDown).frame(width: 3).padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Conversation: \(item.title)")
        .contextMenu {
            Button("Delete conversation", role: .destructive) {
                store.deleteConversation(item.id)
            }
        }
    }

    /// An icon for what the conversation was about.
    private static func symbol(for conversation: ChatConversation) -> String {
        guard let question = conversation.messages.first(where: { $0.role == .user })?.text else {
            return "bubble.left"
        }
        let hasSources = conversation.messages.contains { $0.sources?.isEmpty == false }
        switch TaskHistory.kind(question: question, hasSources: hasSources) {
        case .ask: return "bubble.left"
        case .screen: return "display"
        case .search: return "globe"
        case .action: return "bolt"
        case .fix: return "doc.text"
        case .write: return "pencil"
        }
    }

    /// "Just now", "2m ago", "1h ago", "1d ago".
    private static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "Just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d ago"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            return formatter.string(from: date)
        }
    }

    private func shortcutHint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 44)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ChatTheme.line, lineWidth: 1))
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(ChatTheme.dim)
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(store.selectedConversation?.title ?? "New conversation")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ChatTheme.text.opacity(0.92))
                    .lineLimit(1)
                Spacer()
                if store.isSending {
                    Button { store.cancel() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                }
                Menu {
                    Button("New conversation") {
                        store.createConversation()
                        composerFocused = true
                    }
                    if let id = store.selectedID {
                        Button("Delete conversation", role: .destructive) { store.deleteConversation(id) }
                    }
                    Divider()
                    Button("Close window", action: onDismiss)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More options")
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 14)
            Rectangle().fill(ChatTheme.line).frame(height: 1).padding(.horizontal, 28)

            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if store.selectedConversation?.messages.isEmpty != false {
                            emptyState
                        }
                        ForEach(store.selectedConversation?.messages ?? []) { message in
                            messageRow(message)
                        }
                        if let activity = store.activityMessage {
                            progressRow(activity)
                        } else if store.isSending, store.selectedConversation?.messages.last?.text.isEmpty == true {
                            progressRow(store.isSearchingWeb ? "Searching the web…" : "Writing a response…")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 26)
                }
                .onChange(of: store.selectedConversation?.messages.last?.text) { _ in
                    reader.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: store.selectedID) { _ in
                    reader.scrollTo("bottom", anchor: .bottom)
                }
            }

            if let status = store.statusMessage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.6))
                        Text("Something went wrong")
                            .fontWeight(.semibold)
                        Spacer()
                        Button("Copy Error") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(status, forType: .string)
                        }
                        Button("Retry") { _ = store.retryLast() }
                            .disabled(store.isSending)
                    }
                    ScrollView {
                        Text(status)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 100)
                }
                .font(.system(size: 12))
                .foregroundStyle(ChatTheme.text)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 1.0, green: 0.4, blue: 0.5).opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(red: 1.0, green: 0.45, blue: 0.55).opacity(0.3)))
                .padding(.horizontal, 30)
                .padding(.vertical, 8)
            }
            composer
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(ChatTheme.dim)
        }
        .font(.system(size: 12.5))
        .padding(.leading, 50)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            // Shrinks the headline to fit narrow windows.
            ViewThatFits(in: .horizontal) {
                headline(size: 50)
                headline(size: 40)
                headline(size: 32)
                headline(size: 26)
            }
            Text("Your thoughts, questions, and next steps—together.")
                .font(.system(size: 18))
                .foregroundStyle(ChatTheme.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 14)

            VStack(spacing: 0) {
                Rectangle().fill(ChatTheme.line).frame(height: 1)
                starter("Understand this screen", "Get context, summarize, or take action.", symbol: "display",
                        prompt: "Explain what's on my screen")
                Rectangle().fill(ChatTheme.line).frame(height: 1)
                starter("Polish my writing", "Improve, refine, or change the tone.", symbol: "doc.text",
                        prompt: "Polish this writing: ")
                Rectangle().fill(ChatTheme.line).frame(height: 1)
                starter("Find my next step", "Plan, brainstorm, or get unstuck.", symbol: "arrow.up.right",
                        prompt: "Help me find my next step: ")
            }
            .frame(maxWidth: 640)
            .padding(.top, 44)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private func headline(size: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("A clearer way ")
                .foregroundStyle(.white)
            Text("to think.")
                .foregroundStyle(ChatTheme.rainbow)
                .shadow(color: Color(red: 0.98, green: 0.58, blue: 0.86).opacity(0.35), radius: 16)
        }
        .font(.system(size: size, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
    }

    private func starter(_ title: String, _ detail: String, symbol: String, prompt starterPrompt: String) -> some View {
        Button {
            prompt = starterPrompt
            composerFocused = true
        } label: {
            HStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(detail)
                        .font(.system(size: 13.5))
                        .foregroundStyle(ChatTheme.dim)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let isAssistant = message.role == .assistant
        return HStack(alignment: .top, spacing: 14) {
            Group {
                if isAssistant {
                    BibblesBrandMark(size: 32)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(isAssistant ? "Bibbles" : "You")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isAssistant ? AnyShapeStyle(ChatTheme.rainbow) : AnyShapeStyle(ChatTheme.faint))
                Text(message.text.isEmpty ? " " : (isAssistant ? PlainText.clean(message.text, forAppBundleID: nil) : message.text))
                    .font(.system(size: 14.5))
                    .foregroundStyle(ChatTheme.text.opacity(0.92))
                    .lineSpacing(4.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let sources = message.sources, !sources.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(sources) { source in
                            Link(destination: source.url) {
                                Label(source.title, systemImage: "arrow.up.right")
                                    .lineLimit(1)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(0.06)))
                                    .overlay(Capsule().strokeBorder(ChatTheme.line, lineWidth: 1))
                            }
                            .help(source.url.absoluteString)
                        }
                    }
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isAssistant ? ChatTheme.card : Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(ChatTheme.line, lineWidth: 1)
        )
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !documents.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(documents) { document in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.fill")
                                Text(document.name).lineLimit(1)
                                Button { documents.removeAll { $0.id == document.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.plain)
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            TextEditor(text: $prompt)
                .font(.system(size: 15))
                .foregroundStyle(ChatTheme.text)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .focused($composerFocused)
                .frame(minHeight: 44, maxHeight: 112)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text(dictationHint ? "Hold fn ⌃ and speak…" : (searchWeb ? "Search the web…" : "Ask Bibbles anything…"))
                            .font(.system(size: 15))
                            .foregroundStyle(Color.white.opacity(0.35))
                            .padding(.leading, 5).padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 14) {
                composerButton("Attach", symbol: "paperclip", active: false, action: attachFiles)
                    .help("Attach text, code, or a searchable PDF")
                divider
                composerButton("Web", symbol: "globe", active: searchWeb) { searchWeb.toggle() }
                    .help(searchWeb ? "Search the web for this question" : "Use a quick, source-linked web search")
                divider
                Button {
                    // Dictation types into the focused box: hold fn + Control.
                    composerFocused = true
                    dictationHint = true
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(dictationHint ? 0.95 : 0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hold fn + Control and speak to dictate here")
                Spacer()
                let canSend = !(store.isSending || store.activityMessage != nil
                    || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && documents.isEmpty))
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .frame(width: 52, height: 40)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white))
                        .opacity(canSend ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send (⌘↵)")
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(composerFocused ? 0.16 : 0.1), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            // The glowing rainbow edge along the top.
            ChatTheme.rainbow
                .frame(height: 1.5)
                .padding(.horizontal, 22)
                .shadow(color: Color(red: 0.66, green: 0.55, blue: 1.0).opacity(0.8), radius: 6)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 22)
        .padding(.top, 8)
        .onChange(of: prompt) { _ in dictationHint = false }
    }

    private var divider: some View {
        Rectangle().fill(ChatTheme.line).frame(width: 1, height: 18)
    }

    private func composerButton(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(title).font(.system(size: 13))
            }
            .foregroundStyle(active ? AnyShapeStyle(ChatTheme.rainbow) : AnyShapeStyle(Color.white.opacity(0.75)))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .pdf, .sourceCode]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { documents.append(try ChatDocument.load(from: url)) }
            catch { store.statusMessage = error.localizedDescription }
        }
    }

    private func send() {
        guard onSubmit(prompt, documents, searchWeb) else { return }
        prompt = ""
        documents.removeAll()
        searchWeb = false
    }
}
