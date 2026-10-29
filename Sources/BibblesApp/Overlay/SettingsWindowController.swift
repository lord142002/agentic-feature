import AppKit
import AVFoundation
import AuthenticationServices
import SwiftUI

/// What the Settings window can ask the app to do. Each one reuses the
/// same code as the menu-bar menu.
struct SettingsActions {
    var setNotchHistory: (Bool) -> Void
    var setMenuBarIcon: (Bool) -> Void
    var setVoiceReplies: (Bool) -> Void
    /// Speaks a sample line; returns an error message if it failed.
    /// Speaks a short line in the given voice (nil = the saved voice).
    var previewVoice: @MainActor (String?) async -> String?
    var testVoice: () -> Void
    var editVocabulary: () -> Void
    var teachCorrection: () -> Void
    var reportCorrection: () -> Void
    var clearChatHistory: () -> Void
    var showPermissions: () -> Void
    var showGettingStarted: () -> Void
    /// Saves the voice previews on this Mac so voice cards play instantly.
    var prefetchVoicePreviews: () -> Void = {}
}

/// Bibbles settings in the website's dark violet style.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SettingsModel

    init(actions: SettingsActions) {
        model = SettingsModel(actions: actions)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Bibbles Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.043, green: 0.047, blue: 0.067, alpha: 1)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model, onClose: { [weak self] in self?.hide() }))
    }

    var isVisible: Bool { window.isVisible }

    func show(section: SettingsSection = .general) {
        model.section = section
        model.refresh()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        ProductAnalytics.shared.screen(.settings(section))
    }

    func hide() {
        ProductAnalytics.shared.leaveScreen(.settings(model.section))
        model.meter.stop()
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        ProductAnalytics.shared.leaveScreen(.settings(model.section))
        model.meter.stop()
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case account, general, voice, microphone, dictation, shortcuts, permissions, about
    #if BIBBLES_DEVELOPER
    case developer
    #endif
    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .general: return "General"
        case .voice: return "Voice"
        case .microphone: return "Microphone"
        case .dictation: return "Dictation"
        case .shortcuts: return "Shortcuts"
        case .permissions: return "Permissions"
        case .about: return "About"
        #if BIBBLES_DEVELOPER
        case .developer: return "Developer"
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .general: return "gearshape.fill"
        case .voice: return "waveform"
        case .microphone: return "mic.fill"
        case .dictation: return "character.cursor.ibeam"
        case .shortcuts: return "command"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        #if BIBBLES_DEVELOPER
        case .developer: return "hammer.fill"
        #endif
        }
    }

    /// Sidebar groups, like the website's sections.
    static let app: [SettingsSection] = [.account, .general]
    static let bibbles: [SettingsSection] = [.voice, .microphone, .dictation, .shortcuts]
    /// The Developer page exists only in developer builds (BIBBLES_DEVELOPER).
    @MainActor static var setup: [SettingsSection] {
        #if BIBBLES_DEVELOPER
        [.permissions, .about, .developer]
        #else
        [.permissions, .about]
        #endif
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    let actions: SettingsActions
    let meter = MicrophoneLevelMeter()
    @Published var section: SettingsSection = .general
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var notchHistory = true
    @Published var menuBarIcon = false
    @Published var voiceReplies = true
    @Published var voiceID = OpenRouterSpeech.englishVoice
    @Published var speed = VoiceReplyController.speed
    @Published var dictationMode = DictationPreferences().mode
    @Published var vocabularyCount = 0
    @Published var permissions = PermissionService.snapshot()
    @Published var launchError: String?
    @Published var voiceMessage: String?
    @Published var voiceMessageIsError = false
    /// The voice whose preview is playing, for the card's play button.
    @Published var previewingVoiceID: String?
    private var voicePreviewGeneration = 0

    /// Plays a voice (nil = the saved one) and shows what happened, so a
    /// sign-in or server problem is never silent.
    func previewVoice(_ id: String? = nil) {
        voicePreviewGeneration += 1
        let generation = voicePreviewGeneration
        voiceMessage = "Playing…"
        voiceMessageIsError = false
        previewingVoiceID = id ?? voiceID
        Task { @MainActor in
            let error = await actions.previewVoice(id)
            guard voicePreviewGeneration == generation else { return }
            previewingVoiceID = nil
            if let error {
                voiceMessage = error
                voiceMessageIsError = true
            } else {
                voiceMessage = nil
            }
        }
    }
    @Published var modelPreference = ClaudeAPI.preference

    func setModelPreference(_ preference: ClaudeAPI.ModelPreference) {
        ClaudeAPI.preference = preference
        modelPreference = preference
    }

    init(actions: SettingsActions) {
        self.actions = actions
        refresh()
    }

    func refresh() {
        let defaults = UserDefaults.standard
        launchAtLogin = LaunchAtLogin.isEnabled
        notchHistory = (defaults.object(forKey: "bibbles.notchHistoryEnabled") as? Bool) ?? true
        menuBarIcon = defaults.bool(forKey: "bibbles.showMenuBarIcon")
        voiceReplies = (defaults.object(forKey: "bibbles.voiceRepliesEnabled") as? Bool) ?? true
        voiceID = OpenRouterSpeech.englishVoice
        speed = VoiceReplyController.speed
        dictationMode = DictationPreferences().mode
        vocabularyCount = SpeechVocabularyStore().terms.count
        permissions = PermissionService.snapshot()
        modelPreference = ClaudeAPI.preference
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.setEnabled(on)
            launchError = nil
        } catch {
            launchError = "Couldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func run(_ action: () -> Void) {
        action()
        refresh()
    }
}

/// A short microphone check: shows a live level for a few seconds.
@MainActor
final class MicrophoneLevelMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Tap to test your microphone."
    private var engine: AVAudioEngine?
    private var stopTask: Task<Void, Never>?

    var deviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "No microphone found"
    }

    func start() {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            message = "Bibbles needs microphone access first (Permissions)."
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            message = "No microphone input found."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format,
                         block: Self.levelTap { [weak self] value in
                             Task { @MainActor in self?.level = value }
                         })
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            message = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        self.engine = engine
        isRunning = true
        message = "Speak normally — the bars should move as Bibbles hears you."
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.stop(finished: true)
        }
    }

    /// Runs on the audio thread, so it is kept away from the main actor.
    nonisolated private static func levelTap(_ report: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            report(min(1, (sum / Float(count)).squareRoot() * 14))
        }
    }

    func stop(finished: Bool = false) {
        stopTask?.cancel()
        stopTask = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if isRunning { message = finished ? "Test finished. Tap to test again." : "Tap to test your microphone." }
        isRunning = false
        level = 0
    }
}

// MARK: - Views

private struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(SettingsTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                // Top bar: the page name and a close button.
                HStack {
                    Text(model.section.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                }
                .padding(.horizontal, 26)
                .padding(.top, 26)
                .padding(.bottom, 12)
                Rectangle().fill(SettingsTheme.line).frame(height: 1).padding(.horizontal, 26)
                Group {
                    if model.section == .account {
                        // Account is laid out to fit the window, so it never scrolls.
                        pageBody(top: 22, bottom: 16)
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView { pageBody(top: 42, bottom: 40) }
                    }
                }
                .id(model.section)
            }
            .background(SettingsTheme.background)
        }
        .frame(minWidth: 860, minHeight: 600)
        .environment(\.colorScheme, .dark)
        .tint(BibblesStyle.accent)
    }

    private func pageBody(top: CGFloat, bottom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            page
        }
        .frame(maxWidth: 700, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.top, top)
        .padding(.bottom, bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                BibblesBrandMark(size: 40)
                Text("Bibbles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color(red: 0.86, green: 0.84, blue: 1.0)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
            }
            .padding(.top, 44)
            .padding(.bottom, 26)
            .padding(.horizontal, 8)
            ForEach(SettingsSection.app) { sidebarRow($0) }
            groupLabel("BIBBLES")
            ForEach(SettingsSection.bibbles) { sidebarRow($0) }
            groupLabel("SETUP")
            ForEach(SettingsSection.setup) { sidebarRow($0) }
            Spacer()
            #if BIBBLES_DEVELOPER
            LocalModeBadge()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            #endif
            Text("Bibbles \(SettingsRootView.version)")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
        .frame(width: 250)
        .background(SettingsTheme.sidebar)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? "1"))"
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(1.8)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 4)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let selected = model.section == section
        return Button {
            model.section = section
            ProductAnalytics.shared.screen(.settings(section))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.7))
                    .frame(width: 22)
                Text(section.title)
                    .font(.system(size: 14.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.06) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.white.opacity(0.06) : .clear, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(SettingsTheme.rainbowDown).frame(width: 3).padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .account: AccountPage()
        case .general: GeneralPage(model: model)
        case .voice: VoicePage(model: model)
        case .microphone: MicrophonePage(meter: model.meter, model: model)
        case .dictation: DictationPage(model: model)
        case .shortcuts: ShortcutsPage()
        case .permissions: PermissionsPage(model: model)
        case .about: AboutPage(model: model)
        #if BIBBLES_DEVELOPER
        case .developer: DeveloperPage()
        #endif
        }
    }
}

// MARK: Building blocks

/// Deep night background, soft hairlines and the rainbow accent.
private enum SettingsTheme {
    static let background = Color(red: 0.043, green: 0.047, blue: 0.067)
    static let sidebar = Color(red: 0.035, green: 0.039, blue: 0.055)
    static let line = Color.white.opacity(0.08)
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

private struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.bottom, 26)
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.leading, 6)
            .padding(.top, 8)
            .padding(.bottom, 8)
    }
}

/// A rounded card holding rows, like the website's panels.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                // The glowing rainbow edge along the top of each card.
                SettingsTheme.rainbow
                    .frame(height: 1.5)
                    .padding(.horizontal, 22)
                    .shadow(color: SettingsTheme.rainbowColors[1].opacity(0.8), radius: 5)
            }
            .padding(.bottom, 20)
    }
}

/// Quieter surfaces keep account information readable without the decorative
/// rainbow edge used on the rest of Settings.
private struct QuietPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}

private struct AccountUsageMetric: View {
    let counter: WorkerUsageSnapshot.Counter

    private var fraction: CGFloat {
        guard counter.limit > 0 else { return 0 }
        return CGFloat(min(1, max(0, Double(counter.used) / Double(counter.limit))))
    }

    private var ink: Color {
        fraction >= 0.9 ? Color(red: 1, green: 0.68, blue: 0.49)
            : SettingsTheme.rainbowColors[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(counter.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
                Text(counter.limit > 0 ? "\(counter.remaining.formatted()) left" : "Not included")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            GeometryReader { geometry in
                Capsule().fill(Color.white.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule().fill(ink).frame(width: geometry.size.width * fraction)
                    }
            }
            .frame(height: 3)
            Text("\(counter.used.formatted()) / \(counter.limit.formatted()) used")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct AccountNotice: View {
    let message: String
    let isError: Bool

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isError ? Color(red: 1, green: 0.65, blue: 0.59)
                                     : Color(red: 0.52, green: 0.88, blue: 0.72))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill((isError ? Color.red : Color.green).opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder((isError ? Color.red : Color.green).opacity(0.16), lineWidth: 1))
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(SettingsTheme.line).frame(height: 1).padding(.horizontal, 20)
    }
}

private struct SettingRow<Trailing: View>: View {
    let title: String
    let detail: String
    /// An optional outline icon on the left.
    var symbol: String? = nil
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

/// Buttons: solid white for the main action, outlined for the others.
private struct PillButton: View {
    let title: String
    var prominent = false
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.92))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Color.white : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(prominent ? 0 : 0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StatusBadge: View {
    let ready: Bool
    var readyText = "Set"
    var missingText = "Missing"
    var body: some View {
        Label(ready ? readyText : missingText, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ready ? Color(red: 0.525, green: 0.918, blue: 0.667) : Color(red: 1.0, green: 0.776, blue: 0.443))
    }
}

private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

// MARK: Pages

// MARK: Account sign-in pieces

private struct AuthCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.055), Color.white.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }
}

private struct AuthModeSwitch: View {
    @Binding var creatingAccount: Bool
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            segment("Sign in", selected: !creatingAccount) { creatingAccount = false }
            segment("Create account", selected: creatingAccount) { creatingAccount = true }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    if selected {
                        Capsule().fill(Color.white).matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct AuthInput<Field: View>: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    let isFocused: Bool
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isFocused ? 0.85 : 0.4))
                .frame(width: 16)
            field
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? SettingsTheme.rainbowColors[1].opacity(0.75) : Color.white.opacity(0.09),
                              lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private struct AuthPrimaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(enabled ? AnyShapeStyle(LinearGradient(
                            colors: [SettingsTheme.rainbowColors[0], SettingsTheme.rainbowColors[1]],
                            startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(Color.white.opacity(0.07)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}

private struct AuthProviderButton<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                Text(title).font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct AccountPage: View {
    @ObservedObject private var account = AccountSession.shared
    @State private var projectURL = UserDefaults.standard.string(forKey: "bibbles.supabaseURL") ?? ""
    @State private var publishableKey = UserDefaults.standard.string(forKey: "bibbles.supabasePublishableKey") ?? ""
    @State private var email = ""
    @State private var password = ""
    @State private var newPassword = ""
    @State private var creatingAccount = false
    @State private var otpCode = ""
    @State private var resetPassword = ""
    @State private var resetPasswordConfirm = ""
    @State private var appleNonce = ""
    @State private var confirmingDeletion = false
    @State private var historyExpanded = false
    private let accountAccent = SettingsTheme.rainbowColors[0]
    @FocusState private var focusedAuthField: AuthField?

    private enum AuthField: Hashable { case email, password, code, newPassword, confirmPassword }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Account", subtitle: "Your plan, usage, and sign-in in one place.")
            if let pending = account.pendingVerification {
                verificationCard(pending)
            } else if let signedIn = account.email {
                signedInContent(email: signedIn)
            } else if account.isConfigured {
                AuthCard {
                    VStack(alignment: .leading, spacing: 14) {
                        AuthModeSwitch(creatingAccount: $creatingAccount)

                        VStack(spacing: 8) {
                            AuthInput(icon: "envelope", placeholder: "Email address", text: $email,
                                      isFocused: focusedAuthField == .email) {
                                TextField("", text: $email, prompt: Text("Email address").foregroundColor(.white.opacity(0.35)))
                                    .focused($focusedAuthField, equals: .email)
                                    .onSubmit { focusedAuthField = .password }
                            }
                            AuthInput(icon: "lock", placeholder: "Password", text: $password,
                                      isFocused: focusedAuthField == .password) {
                                HStack(spacing: 8) {
                                    SecureField("", text: $password,
                                                prompt: Text(creatingAccount ? "Password (8+ characters)" : "Password")
                                                    .foregroundColor(.white.opacity(0.35)))
                                        .focused($focusedAuthField, equals: .password)
                                        .onSubmit(submitEmail)
                                    if !creatingAccount {
                                        Button("Forgot?") { Task { await account.resetPassword(email: email) } }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(.white.opacity(email.contains("@") ? 0.7 : 0.3))
                                            .disabled(account.isBusy || !email.contains("@"))
                                            .help("Email me a password reset link")
                                    }
                                }
                            }
                        }

                        AuthPrimaryButton(title: creatingAccount ? "Create Account" : "Sign In",
                                          enabled: canSubmitEmail) { submitEmail() }

                        HStack(spacing: 12) {
                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                            Text("or continue with")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                                .fixedSize()
                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                        }

                        HStack(spacing: 10) {
                            if account.appleEnabled && AccountSession.nativeAppleSignInEnabled {
                                SignInWithAppleButton(creatingAccount ? .signUp : .signIn, onRequest: { request in
                                    appleNonce = account.prepareAppleRequest(request)
                                }, onCompletion: { result in
                                    Task { await account.completeAppleSignIn(result, nonce: appleNonce) }
                                })
                                .signInWithAppleButtonStyle(.white)
                                .frame(height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .disabled(account.isBusy)
                            } else {
                                AuthProviderButton(title: "Apple") {
                                    Image(systemName: "apple.logo").font(.system(size: 15, weight: .medium))
                                } action: {
                                    Task { await account.signInWithAppleWeb() }
                                }
                                .disabled(account.isBusy)
                            }
                            AuthProviderButton(title: "Google") {
                                Text("G").font(.system(size: 15, weight: .bold, design: .rounded))
                            } action: {
                                Task { await account.signInWithGoogle() }
                            }
                            .disabled(account.isBusy)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: creatingAccount)
                .onChange(of: account.switchToSignIn) { flagged in
                    guard flagged else { return }
                    creatingAccount = false
                    password = ""
                    focusedAuthField = .password
                    account.acknowledgeSwitchToSignIn()
                }
                .onAppear {
                    if !account.googleEnabled && !account.appleEnabled { account.refreshProviders() }
                }
            }

            if account.isBusy {
                ProgressView("Updating your account…")
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .padding(.top, 12)
            }
            if let message = account.message {
                AccountNotice(message: message, isError: false)
                    .padding(.top, 12)
            }
            if let error = account.errorMessage {
                AccountNotice(message: error, isError: true)
                    .padding(.top, 12)
            }
            if account.email == nil {
                Label("Your chat history stays on this Mac.", systemImage: "lock.shield")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.48))
                    .padding(.top, 12)
            }

            if !account.isConfigured {
                SectionLabel(text: "Account service setup")
                QuietPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect the Bibbles Supabase project. Only its public project URL and publishable key belong here.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        TextField("https://your-project.supabase.co", text: $projectURL)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Publishable / anon key", text: $publishableKey)
                            .textFieldStyle(.roundedBorder)
                        PillButton(title: "Connect Project", prominent: true) {
                            do {
                                try account.configure(urlString: projectURL, publishableKey: publishableKey)
                                publishableKey = ""
                            } catch { accountSetupError = error.localizedDescription }
                        }
                        if let accountSetupError {
                            Text(accountSetupError).font(.system(size: 12)).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .task(id: account.email) {
            if account.email != nil { await account.refreshWorkerUsage() }
        }
        .alert("Delete your Bibbles account?", isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) { Task { await account.deleteAccount() } }
        } message: {
            Text("This permanently deletes your account and server-side data. This action cannot be undone. Local chat history remains on this Mac unless you clear it separately.")
        }
    }

    // MARK: Email code (sign-up / password reset)

    private func verificationCard(_ pending: AccountSession.PendingVerification) -> some View {
        AuthCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button { Task { await account.cancelVerification(); clearVerificationFields() } } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Back")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verificationTitle(pending))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(pending.stage == .code
                             ? "Enter the code we sent to \(pending.email)"
                             : "For \(pending.email) · at least 8 characters")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                if pending.stage == .code {
                    AuthInput(icon: "number", placeholder: "Code", text: $otpCode,
                              isFocused: focusedAuthField == .code) {
                        TextField("", text: $otpCode, prompt: Text("Verification code").foregroundColor(.white.opacity(0.35)))
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .focused($focusedAuthField, equals: .code)
                            .onChange(of: otpCode) { value in
                                let digits = String(value.filter(\.isNumber).prefix(10))
                                if digits != value { otpCode = digits }
                            }
                            .onSubmit(submitCode)
                    }
                    AuthPrimaryButton(title: "Verify", enabled: canSubmitCode) { submitCode() }
                    HStack {
                        Text("Didn’t get it? Check spam, or")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                        Button("resend code") { Task { await account.resendCode() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(SettingsTheme.rainbowColors[0])
                            .disabled(account.isBusy)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 8) {
                        AuthInput(icon: "lock", placeholder: "New password", text: $resetPassword,
                                  isFocused: focusedAuthField == .newPassword) {
                            SecureField("", text: $resetPassword,
                                        prompt: Text("New password").foregroundColor(.white.opacity(0.35)))
                                .focused($focusedAuthField, equals: .newPassword)
                                .onSubmit { focusedAuthField = .confirmPassword }
                        }
                        AuthInput(icon: "lock.rotation", placeholder: "Confirm password", text: $resetPasswordConfirm,
                                  isFocused: focusedAuthField == .confirmPassword) {
                            SecureField("", text: $resetPasswordConfirm,
                                        prompt: Text("Confirm new password").foregroundColor(.white.opacity(0.35)))
                                .focused($focusedAuthField, equals: .confirmPassword)
                                .onSubmit(submitNewPassword)
                        }
                    }
                    if !resetPasswordConfirm.isEmpty && resetPassword != resetPasswordConfirm {
                        Label("Passwords don’t match", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.59))
                    } else if !resetPassword.isEmpty && resetPassword.count < 8 {
                        Text("Use at least 8 characters.")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                    }
                    AuthPrimaryButton(title: "Save password", enabled: canSubmitNewPassword) { submitNewPassword() }
                }
            }
        }
        .onAppear { focusedAuthField = pending.stage == .code ? .code : .newPassword }
        .onChange(of: pending.stage) { stage in
            focusedAuthField = stage == .code ? .code : .newPassword
        }
    }

    private func verificationTitle(_ pending: AccountSession.PendingVerification) -> String {
        switch (pending.kind, pending.stage) {
        case (.signup, _): return "Verify your email"
        case (.recovery, .code): return "Reset your password"
        case (.recovery, .newPassword): return "Choose a new password"
        }
    }

    private var canSubmitCode: Bool { !account.isBusy && otpCode.count >= 6 }

    private var canSubmitNewPassword: Bool {
        !account.isBusy && resetPassword.count >= 8 && resetPassword == resetPasswordConfirm
    }

    private func submitCode() {
        guard canSubmitCode else { return }
        let code = otpCode
        Task {
            await account.verifyCode(code)
            if account.errorMessage == nil { otpCode = "" }
        }
    }

    private func submitNewPassword() {
        guard canSubmitNewPassword else { return }
        let replacement = resetPassword
        Task {
            await account.setNewPassword(replacement)
            if account.errorMessage == nil { clearVerificationFields() }
        }
    }

    private func clearVerificationFields() {
        otpCode = ""
        resetPassword = ""
        resetPasswordConfirm = ""
        password = ""
    }

    private var canSubmitEmail: Bool {
        !account.isBusy && account.emailEnabled && email.contains("@") &&
            !password.isEmpty && (!creatingAccount || password.count >= 8)
    }

    private func submitEmail() {
        guard !account.isBusy, account.emailEnabled, email.contains("@"), !password.isEmpty,
              !creatingAccount || password.count >= 8 else { return }
        let suppliedEmail = email
        let suppliedPassword = password
        let isCreating = creatingAccount
        Task {
            if isCreating { await account.signUp(email: suppliedEmail, password: suppliedPassword) }
            else { await account.signIn(email: suppliedEmail, password: suppliedPassword) }
            if account.errorMessage == nil {
                password = ""
                focusedAuthField = nil
            }
        }
    }

    private var currentPlanName: String? { account.effectivePlanName }

    private var isPremium: Bool { PlanEntitlement.isPremium(plan: currentPlanName) }

    private func signedInContent(email signedIn: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            planHeroCard(email: signedIn)
            usageCard

            if account.needsNewPassword {
                QuietPanel {
                    HStack(spacing: 10) {
                        SecureField("New password (8+ characters)", text: $newPassword)
                            .textFieldStyle(.roundedBorder)
                        PillButton(title: "Update", prominent: true) {
                            let replacement = newPassword
                            newPassword = ""
                            Task { await account.updatePassword(replacement) }
                        }
                        .disabled(account.isBusy || newPassword.count < 8)
                    }
                }
            }

            HStack(spacing: 16) {
                Label("Your chat history stays on this Mac.", systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
                Spacer()
                Button("Plan history") { historyExpanded = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .popover(isPresented: $historyExpanded, arrowEdge: .top) { planHistoryPopover }
                Button("Delete account…") { confirmingDeletion = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55).opacity(0.85))
                    .disabled(account.isBusy)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
    }

    // MARK: Plan card

    private func planHeroCard(email signedIn: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Text(String(signedIn.prefix(1)).uppercased())
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(LinearGradient(
                        colors: [SettingsTheme.rainbowColors[0], SettingsTheme.rainbowColors[1]],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(signedIn)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Label("Connected to Bibbles Cloud", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.52, green: 0.88, blue: 0.72))
                }
                Spacer(minLength: 8)
                planBadge
                Button("Sign out") { Task { await account.signOut() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.leading, 6)
                    .disabled(account.isBusy)
            }
            .padding(18)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            HStack(spacing: 13) {
                Image(systemName: isPremium ? "calendar.badge.clock" : "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isPremium ? SettingsTheme.rainbowColors[1] : SettingsTheme.rainbowColors[3])
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.05)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(planLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(planDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(planDetailIsWarning ? Color(red: 1, green: 0.68, blue: 0.49) : .white.opacity(0.5))
                }
                Spacer(minLength: 8)
                if let action = planAction {
                Button {
                    switch action.kind {
                    case .plans: PlansWindowController.shared.show()
                    case .manage: Task { await account.openBillingPortal() }
                    }
                } label: {
                    Label {
                        Text(account.billingBusy ? "Opening…" : action.title)
                    } icon: {
                        if account.billingBusy {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: action.icon)
                        }
                    }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Capsule().fill(LinearGradient(
                            colors: [SettingsTheme.rainbowColors[0], SettingsTheme.rainbowColors[1], SettingsTheme.rainbowColors[2]],
                            startPoint: .leading, endPoint: .trailing)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(account.billingBusy)
                .help(action.kind == .plans ? "See Alpha, Sigma and Omega" : "Change card, see invoices, or cancel")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.055), Color.white.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isPremium
                              ? AnyShapeStyle(LinearGradient(colors: SettingsTheme.rainbowColors.map { $0.opacity(0.45) },
                                                             startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(Color.white.opacity(0.09)), lineWidth: 1)
        )
    }

    private enum PlanActionKind { case plans, manage }

    /// Free → Upgrade, paid → Change plan: both open the "Choose your plan" window
    /// (Alpha / Sigma / Omega), which leads to Dodo checkout.
    private var planAction: (title: String, icon: String, kind: PlanActionKind)? {
        guard isPremium else { return ("Upgrade", "arrow.up.circle.fill", .plans) }
        return ("Change plan", "arrow.up.arrow.down.circle.fill", .plans)
    }

    private var planBadge: some View {
        let name = currentPlanName?.replacingOccurrences(of: "_", with: " ").capitalized ?? "—"
        return HStack(spacing: 5) {
            if isPremium { Image(systemName: "crown.fill").font(.system(size: 9.5, weight: .bold)) }
            Text(name).font(.system(size: 11.5, weight: .bold))
        }
        .foregroundStyle(isPremium ? Color.black : Color.white.opacity(0.75))
        .padding(.horizontal, 11)
        .frame(height: 24)
        .background(
            Capsule().fill(isPremium
                           ? AnyShapeStyle(LinearGradient(colors: [SettingsTheme.rainbowColors[3], SettingsTheme.rainbowColors[2]],
                                                          startPoint: .leading, endPoint: .trailing))
                           : AnyShapeStyle(Color.white.opacity(0.08)))
        )
    }

    private var planLine: String {
        if account.awaitingPayment && !isPremium { return "Waiting for payment confirmation…" }
        guard isPremium else { return "You’re on the Alpha (free) plan" }
        let entitlement = account.planEntitlement
        if let expires = entitlement?.expiresAt {
            return expires < Date() ? "Premium expired on \(planDate(expires))" : "Premium until \(planDate(expires))"
        }
        if let renews = entitlement?.renewsAt { return "Renews on \(planDate(renews))" }
        if account.usageIsRefreshing { return "Checking your plan…" }
        return "Premium is active"
    }

    private var planDetail: String {
        if account.awaitingPayment && !isPremium { return "This updates by itself a few seconds after you pay." }
        guard isPremium else { return "Upgrade to Sigma or Omega for more asks and deep tasks." }
        guard let expires = account.planEntitlement?.expiresAt else {
            return account.planEntitlement?.renewsAt != nil ? "Auto-renewing plan" : "No expiry date on file"
        }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: expires)).day ?? 0
        if days < 0 { return "Buy a plan to keep using Premium" }
        if days == 0 { return "Expires today" }
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    private var planDetailIsWarning: Bool {
        guard isPremium, let expires = account.planEntitlement?.expiresAt else { return false }
        return expires.timeIntervalSinceNow < 7 * 86_400
    }

    // MARK: Usage card

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Monthly usage")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                if let month = account.workerUsage?.month {
                    Text(monthTitle(month))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                if account.usageIsRefreshing {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing usage")
                } else {
                    Button { Task { await account.refreshWorkerUsage() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh usage and plan")
                    .accessibilityLabel("Refresh monthly usage")
                }
            }
            #if BIBBLES_DEVELOPER
            if LocalMode.isOn, let cached = LocalUsageCache.load() {
                Text(cached.label)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.orange.opacity(0.9))
            }
            #endif
            if let counters = shownCounters, !counters.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: min(3, counters.count)),
                          alignment: .leading, spacing: 4) {
                    ForEach(counters) { counter in AccountUsageMetric(counter: counter) }
                }
            } else {
                Text(account.usageError ?? (account.usageIsRefreshing ? "Loading your usage…" : "Usage is not available yet."))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    /// Only these limits are shown here; the server still tracks and enforces all of them.
    private static let visibleCounterIDs = ["asks", "deep_tasks", "deep", "screen_help"]

    private var shownCounters: [WorkerUsageSnapshot.Counter]? {
        account.workerUsage?.counters
            .filter { Self.visibleCounterIDs.contains($0.id.lowercased()) }
            .sorted { Self.visibleCounterIDs.firstIndex(of: $0.id.lowercased()) ?? 0
                    < Self.visibleCounterIDs.firstIndex(of: $1.id.lowercased()) ?? 0 }
    }

    private func monthTitle(_ month: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: month) else { return month }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }

    // MARK: Plan history

    /// Finished periods: the billing service's record, else the Worker's.
    private var pastPlans: [WorkerUsageSnapshot.PastPlan] {
        if let billing = account.billingStatus, !billing.history.isEmpty { return billing.history }
        return account.workerUsage?.planHistory ?? []
    }

    private var planHistoryPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan history").font(.system(size: 13, weight: .semibold))
            // The plan you're on now.
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(SettingsTheme.rainbowColors[4]).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text((currentPlanName ?? "alpha").replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 12, weight: .semibold))
                    Text(currentPlanSince)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Text("Current").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.rainbowColors[4])
            }
            let history = pastPlans
            if !history.isEmpty {
                ForEach(history.indices, id: \.self) { index in
                    let period = history[index]
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(accountAccent).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(period.plan.capitalized).font(.system(size: 12, weight: .semibold))
                            Text("\(planDate(period.startedAt)) – \(planDate(period.endedAt))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Text(period.endReason.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(isPremium ? "No earlier paid plans." : "No paid plans yet.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 300, alignment: .leading)
    }

    private var currentPlanSince: String {
        guard isPremium else { return "Free plan" }
        let since = account.billingStatus?.currentSince ?? account.planEntitlement?.startedAt
        let until: String = {
            if let ends = account.planEntitlement?.expiresAt { return " · ends \(planDate(ends))" }
            if let renews = account.planEntitlement?.renewsAt { return " · renews \(planDate(renews))" }
            return ""
        }()
        return (since.map { "Since \(planDate($0))" } ?? "Active") + until
    }

    private func planDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    @State private var accountSetupError: String?
}

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var analytics = ProductAnalytics.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "General", subtitle: "How Bibbles behaves on your Mac.")
            SectionLabel(text: "Behavior")
            Card {
                SettingRow(title: "Open at login", detail: "Start Bibbles automatically when you log in.") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(title: "Task history at the notch",
                           detail: "Hover the Bibbles bar around the notch to see what Bibbles has done. Hidden in full-screen apps.") {
                    Toggle("", isOn: Binding(get: { model.notchHistory }, set: { on in
                        model.notchHistory = on
                        model.actions.setNotchHistory(on)
                    }))
                    .toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(title: "Icon in the menu bar",
                           detail: model.notchHistory
                               ? "The notch already has everything, so this is off by default. Turn on for the classic menu."
                               : "Always shown while the notch bar is off, so you can still reach Bibbles.") {
                    Toggle("", isOn: Binding(get: { model.menuBarIcon || !model.notchHistory }, set: { on in
                        model.menuBarIcon = on
                        model.actions.setMenuBarIcon(on)
                    }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(!model.notchHistory)
                }
                RowDivider()
                SettingRow(title: "Speak answers aloud", detail: "Read answers to spoken questions in your chosen voice.") {
                    Toggle("", isOn: Binding(get: { model.voiceReplies }, set: { on in
                        model.voiceReplies = on
                        model.actions.setVoiceReplies(on)
                    }))
                    .toggleStyle(.switch).labelsHidden()
                }
            }
            if let error = model.launchError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).padding(.leading, 6).padding(.bottom, 12)
            }
            SectionLabel(text: "Privacy")
            Card {
                SettingRow(title: "Share product analytics",
                           detail: "Optional feature-use counts help improve Bibbles. No questions, answers, recordings, screenshots, files, emails or payment details are collected. Session replay is disabled.") {
                    Toggle("", isOn: Binding(get: { analytics.hasConsent }, set: { analytics.setConsent($0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Share product analytics")
                }
            }
            SectionLabel(text: "History")
            Card {
                SettingRow(title: "Chat and task history", detail: "Saved only on this Mac. Clearing it also empties the task history.") {
                    PillButton(title: "Clear History…") { model.run(model.actions.clearChatHistory) }
                }
            }
        }
    }
}

extension GeneralPage {
    func qualityRow(_ preference: ClaudeAPI.ModelPreference, _ title: String, _ detail: String) -> some View {
        // Fixed on Auto: every option is shown, none can be changed.
        let selected = preference == .auto
        return Button { model.setModelPreference(preference) } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? BibblesStyle.accent : Color.white.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    if selected {
                        Circle().fill(BibblesStyle.accent).frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(false)
    }
}

private struct VoicePage: View {
    @ObservedObject var model: SettingsModel
    private let speeds: [Double] = [0.75, 1.0, 1.25, 1.5]
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Voice", subtitle: "The voice Bibbles answers in, and how fast it talks.")
            SectionLabel(text: "Speech speed")
            HStack(spacing: 8) {
                ForEach(speeds, id: \.self) { value in
                    let selected = abs(model.speed - value) < 0.01
                    Button {
                        model.speed = value
                        VoiceReplyController.speed = value
                    } label: {
                        Text(value == 1 ? "1x" : String(format: "%gx", value))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selected ? .white : .white.opacity(0.7))
                            .frame(width: 70, height: 36)
                            .background(
                                Capsule().fill(selected
                                    ? AnyShapeStyle(LinearGradient(colors: [BibblesStyle.accent, BibblesStyle.accentSecondary],
                                                                   startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.white.opacity(0.07)))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(BibblesStyle.hairline, lineWidth: 1))
            Text("Takes effect on the next spoken answer.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 6).padding(.top, 8).padding(.bottom, 20)

            SectionLabel(text: "Voice")
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(OpenRouterSpeech.englishVoices, id: \.id) { voice in
                    voiceCard(id: voice.id, name: voice.name)
                }
            }
            .padding(.bottom, 14)
            .onAppear { model.actions.prefetchVoicePreviews() }
            if let message = model.voiceMessage {
                Label(message, systemImage: model.voiceMessageIsError ? "exclamationmark.triangle.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(model.voiceMessageIsError ? Color.orange : BibblesStyle.accentDeep)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 6).padding(.top, 12)
            }
            Text("Speech requires sign-in and uses your monthly account allowance.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 6).padding(.top, 12).padding(.bottom, 22)

            SectionLabel(text: "Check")
            Card {
                SettingRow(title: "Test voice", detail: "Generates a short spoken line through Bibbles Cloud.") {
                    PillButton(title: "Test Voice", prominent: true) { model.actions.testVoice() }
                }
            }
        }
    }

    private func voiceCard(id: String, name: String) -> some View {
        let selected = model.voiceID == id
        let info = VoiceStyle.info(for: id)
        let title = name.components(separatedBy: " (").first ?? name
        let playing = model.previewingVoiceID == id
        return Button {
            // Saved under "bibbles.geminiVoice"; used for every language.
            OpenRouterSpeech.englishVoice = id
            model.voiceID = id
            model.previewVoice(id)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: info.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(info.color)
                    .frame(height: 38)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(info.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? BibblesStyle.accent.opacity(0.14) : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? BibblesStyle.accent : BibblesStyle.hairline, lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white, BibblesStyle.accent)
                        .padding(10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Use and hear \(title)")
        .overlay(alignment: .topLeading) {
            if playing {
                // Shown while this voice is speaking.
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(BibblesStyle.accent)
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }
}

private enum VoiceStyle {
    static func info(for id: String) -> (symbol: String, tagline: String, color: Color) {
        switch id {
        case "Kore": return ("waveform", "Firm & clear", BibblesStyle.accentSecondary)
        case "Puck": return ("sparkles", "Upbeat", Color(red: 1.0, green: 0.82, blue: 0.4))
        case "Zephyr": return ("sun.max.fill", "Bright", Color(red: 1.0, green: 0.74, blue: 0.38))
        case "Charon": return ("book.fill", "Informative", Color(red: 0.45, green: 0.75, blue: 1.0))
        case "Aoede": return ("wind", "Breezy", Color(red: 0.38, green: 0.86, blue: 0.82))
        case "Sulafat": return ("heart.fill", "Warm", Color(red: 0.996, green: 0.49, blue: 0.56))
        case "Achird": return ("face.smiling", "Friendly", Color(red: 0.49, green: 0.85, blue: 0.6))
        default: return ("person.wave.2.fill", "Natural", BibblesStyle.accent)
        }
    }
}

private struct MicrophonePage: View {
    @ObservedObject var meter: MicrophoneLevelMeter
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Microphone", subtitle: "Which microphone Bibbles listens through.")
            SectionLabel(text: "Input device")
            Card {
                SettingRow(title: meter.deviceName, detail: "Bibbles uses your Mac's current input. Change it in Sound settings.") {
                    PillButton(title: "Sound Settings…") {
                        let modern = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
                        let classic = URL(string: "x-apple.systempreferences:com.apple.preference.sound")!
                        if !NSWorkspace.shared.open(modern) { NSWorkspace.shared.open(classic) }
                    }
                }
            }
            SectionLabel(text: "Test")
            Card {
                HStack(spacing: 18) {
                    PillButton(title: meter.isRunning ? "Stop" : "Test microphone", prominent: !meter.isRunning) {
                        if meter.isRunning { meter.stop() } else { meter.start() }
                    }
                    LevelBars(level: meter.level)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                Text(meter.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
            }
        }
    }
}

private struct LevelBars: View {
    let level: Float
    private let count = 16
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                let lit = Float(index) / Float(count) < level
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(lit ? BibblesStyle.barColors[index % BibblesStyle.barColors.count] : Color.white.opacity(0.1))
                    .frame(width: 8, height: 28)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

private struct DictationPage: View {
    @ObservedObject var model: SettingsModel
    @State private var speechLanguage = SpeechLanguage.current
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Dictation", subtitle: "How fn ⌃ types what you say into any app.")
            SectionLabel(text: "Language")
            Card {
                SettingRow(title: ToolGateStrings.speechLanguageTitle, detail: ToolGateStrings.speechLanguageDetail) {
                    Picker(ToolGateStrings.speechLanguageTitle, selection: $speechLanguage) {
                        ForEach(SpeechLanguage.all) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 230)
                    .onChange(of: speechLanguage) { SpeechLanguage.current = $0 }
                }
            }
            SectionLabel(text: "Style")
            HStack(spacing: 14) {
                modeCard(.clean, symbol: "wand.and.stars", detail: "Removes ums, fixes punctuation and capitals.")
                modeCard(.verbatim, symbol: "text.quote", detail: "Types every word exactly as you said it.")
            }
            .padding(.bottom, 22)
            SectionLabel(text: "Accuracy")
            Card {
                SettingRow(title: "Technical vocabulary",
                           detail: "Names, code words and Hinglish phrases Bibbles should recognise (\(model.vocabularyCount)/100).") {
                    PillButton(title: "Edit…") { model.run(model.actions.editVocabulary) }
                }
                RowDivider()
                SettingRow(title: "Teach a correction", detail: "When Bibbles keeps mishearing a word, tell it the right one.") {
                    PillButton(title: "Teach…") { model.run(model.actions.teachCorrection) }
                }
                RowDivider()
                SettingRow(title: "Fix the last dictation", detail: "Correct what Bibbles typed so it learns for next time.") {
                    PillButton(title: "Correct…") { model.run(model.actions.reportCorrection) }
                }
            }
        }
    }

    private func modeCard(_ mode: DictationOutputMode, symbol: String, detail: String) -> some View {
        let selected = model.dictationMode == mode
        return Button {
            DictationPreferences().mode = mode
            model.dictationMode = mode
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? BibblesStyle.accentDeep : .white.opacity(0.6))
                Text(mode.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? BibblesStyle.accent.opacity(0.14) : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? BibblesStyle.accent : BibblesStyle.hairline, lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Shortcuts", subtitle: "The keys that summon Bibbles.")
            SectionLabel(text: "Talk to Bibbles")
            Card {
                shortcut("Push to talk", "Hold, ask anything or about your screen, release to send.", ["⌃ control", "⌥ option"])
                RowDivider()
                shortcut("Type to Bibbles", "Press control twice to type instead of talking.", ["⌃ control", "⌃ control"])
                RowDivider()
                shortcut("Open chat", "Your conversations and history.", ["⌃ control", "⌘ command", "A"])
            }
            SectionLabel(text: "Dictation")
            Card {
                shortcut("Dictate", "Hold and speak. Release to type what you said at your cursor.", ["fn", "⌃ control"])
            }
            SectionLabel(text: "Anywhere")
            Card {
                shortcut("Close", "Close Bibbles' answer, chat or drawings.", ["esc"])
                RowDivider()
                shortcut("Task history", "Hover the Bibbles bar around the notch.", ["notch"])
            }
        }
    }

    private func shortcut(_ title: String, _ detail: String, _ keys: [String]) -> some View {
        SettingRow(title: title, detail: detail) {
            HStack(spacing: 6) { ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap(text: $0.element) } }
        }
    }
}

private struct PermissionsPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Permissions", subtitle: "What macOS lets Bibbles do. Rebuilding the app can reset these.")
            Card {
                row("Microphone", "To hear your questions and dictation.", "mic", model.permissions.microphone == .authorized)
                RowDivider()
                row("Accessibility", "To type answers and dictation into your apps.", "accessibility", model.permissions.accessibility)
                RowDivider()
                row("Screen Recording", "To see your screen when you ask about it.", "display", model.permissions.screenRecording)
            }
            HStack(spacing: 10) {
                PillButton(title: "Fix Permissions…", prominent: true) { model.run(model.actions.showPermissions) }
                PillButton(title: "Check Again", symbol: "arrow.clockwise") { model.refresh() }
            }
            .padding(.leading, 4)
        }
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ granted: Bool) -> some View {
        SettingRow(title: title, detail: detail, symbol: symbol) {
            StatusBadge(ready: granted, readyText: "Allowed", missingText: "Not allowed")
        }
    }
}

private struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "About", subtitle: "A thoughtful companion for your Mac.")

            QuietPanel {
                HStack(alignment: .center, spacing: 16) {
                    BibblesBrandMark(size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Bibbles")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(BibblesIdentity.attribution)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Version \(SettingsRootView.version)  ·  macOS 13+")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
            }

            SectionLabel(text: "Made for your workflow")
            QuietPanel {
                VStack(alignment: .leading, spacing: 15) {
                    feature("Ask", detail: "Get clear answers about your work or what is visible on screen.", symbol: "magnifyingglass")
                    Rectangle().fill(SettingsTheme.line).frame(height: 1)
                    feature("Dictate", detail: "Turn your voice into text in the app you are using.", symbol: "waveform")
                    Rectangle().fill(SettingsTheme.line).frame(height: 1)
                    feature("Guide", detail: "Find controls and follow grounded, on-screen steps.", symbol: "cursorarrow")
                }
            }

            SectionLabel(text: "Privacy")
            QuietPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your conversation history stays on this Mac.", systemImage: "lock")
                    Label("AI requests use the authenticated Bibbles Cloud service.", systemImage: "network")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.68))
            }

            SectionLabel(text: "Learn more")
            QuietPanel {
                HStack(spacing: 10) {
                    PillButton(title: "Getting started", symbol: "book") { model.actions.showGettingStarted() }
                    PillButton(title: BibblesIdentity.domain, symbol: "arrow.up.right") {
                        NSWorkspace.shared.open(BibblesIdentity.website)
                    }
                }
            }
        }
    }

    private func feature(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if BIBBLES_DEVELOPER
// MARK: - Developer (developer builds only)

/// Shown on Settings while Local mode is on.
private struct LocalModeBadge: View {
    @ObservedObject private var controls = DeveloperControls.shared

    var body: some View {
        if controls.localMode {
            Text("LOCAL MODE")
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.orange))
                .accessibilityLabel("Local mode is on")
        }
    }
}

/// The same controls as the Option-click Developer menu, for testing the
/// Tool Gate, keyword improvements and the AI router. Shown only in
/// developer builds.
@MainActor
private struct DeveloperPage: View {
    @ObservedObject private var controls = DeveloperControls.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Developer", subtitle: "Testing controls for routing, your own API keys, Local mode and agents. Developer builds only.")
            if let warning = controls.warning {
                AccountNotice(message: warning, isError: true).padding(.bottom, 18)
            }
            SectionLabel(text: "Local mode")
            Card {
                SettingRow(title: "Local mode (use my keys, skip the server)",
                           detail: "Off: everything goes through the Bibbles server, exactly as for customers. On: every feature calls the providers directly with your keys below, and Bibbles makes no request to its server at all (not even usage). Plan limits are shown from the last sync but not counted. Your sign-in stays as it is.") {
                    HStack(spacing: 10) {
                        LocalModeBadge()
                        Toggle("", isOn: Binding(get: { controls.localMode }, set: { controls.setLocalMode($0) }))
                            .toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel("Local mode")
                    }
                }
                if let warning = controls.localModeWarning {
                    AccountNotice(message: warning, isError: true)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 16)
                }
            }
            SectionLabel(text: "Agents")
            Card {
                toggleRow("AI Agents (Files)",
                          "Requests like \"Clean up my Downloads folder\" or \"Organize my screenshots by month\" (any language) plan rules with one AI call, show a preview, change nothing before Start, and can be undone for 30 minutes. Local mode only for now. Off: today's behaviour.",
                          isOn: controls.filesAgent, set: { controls.setFilesAgent($0) })
                if controls.filesAgent && !controls.localMode {
                    AccountNotice(message: "Turn on Local mode above: agents use your keys for now.", isError: true)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 16)
                }
                RowDivider()
                SettingRow(title: "Run Agent Plan Test Set",
                           detail: "Plans \(AgentPlanTestSet.cases.count) Files requests (EN, ES, DE, FR, PT, JA, Hindi/Hinglish) against a fake folder summary on every planner with a saved key. Planning only, no files touched. Copies valid JSON %, allowed actions %, correct plan %, average and slowest ms and cost per plan.") {
                    PillButton(title: controls.agentTestRunning ? "Running…" : "Run", prominent: !controls.agentTestRunning,
                               symbol: controls.agentTestRunning ? nil : "play.fill") { controls.runAgentPlanTestSet() }
                        .disabled(controls.agentTestRunning)
                }
                if let progress = controls.agentTestProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                        Text("\(progress.done) of \(progress.total) plans")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
            }
            SectionLabel(text: "Routing")
            Card {
                toggleRow("Tool Gate",
                          "Decides each request's route, prompt and AI tier on this Mac before any AI call (no network). Off = the older routing.",
                          isOn: controls.toolGate, set: { controls.setToolGate($0) })
                RowDivider()
                toggleRow("Keyword improvements",
                          "Finds the request anywhere in long speech: splits it into clauses, ignores filler words (uh, um, äh, えっと…) and negations like \"I can't write today\". Routing only; your words are sent unchanged.",
                          isOn: controls.keywordImprovements, set: { controls.setKeywordImprovements($0) })
                RowDivider()
                toggleRow("AI Router (Haiku)",
                          "On for everyone. When keywords can't decide, Claude Haiku labels the request (write, fix, screen, search…) through the Bibbles server. Sends only the words and on/off flags, never screenshots, files or selected text. Used at ≥ 0.75 confidence; otherwise, or after 1.5 s, keywords decide.",
                          isOn: controls.aiRouter, set: { controls.setAIRouter($0) })
            }
            SectionLabel(text: "API keys (local testing)")
            Card {
                ForEach(Array(DeveloperKeySlot.allCases.enumerated()), id: \.element) { index, slot in
                    if index > 0 { RowDivider() }
                    keyRow(slot)
                }
            }
            SectionLabel(text: "Router test set")
            Card {
                SettingRow(title: "Run Router Test Set",
                           detail: "Sends \(RouterTestSet.cases.count) test phrases to the router only: no answers, no Worker requests. Compares old keywords, new keywords and new keywords + router, and copies the report to the clipboard.") {
                    PillButton(title: controls.testRunning ? "Running…" : "Run", prominent: !controls.testRunning,
                               symbol: controls.testRunning ? nil : "play.fill") { controls.runTestSet() }
                        .disabled(controls.testRunning || !controls.hasRouterKey)
                }
                if let progress = controls.testProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                        Text("\(progress.done) of \(progress.total) phrases")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
            }
            SectionLabel(text: "Models (local testing)")
            Card {
                ForEach(Array(ModelFeature.allCases.enumerated()), id: \.element) { index, feature in
                    if index > 0 { RowDivider() }
                    modelRow(feature)
                }
                Text("Pinned IDs, verified \(ModelCatalog.verifiedOn) (docs/MODELS.md). Used only in Local mode; model choices are saved on this Mac, keys never are.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
            }
            SectionLabel(text: "Local mode cost log")
            Card {
                SettingRow(title: "Estimated cost",
                           detail: "\(controls.costCount) Local mode requests, about \(ModelCatalog.formatted(controls.costTotal)) in total (tokens × the price table in docs/MODELS.md). Feature, model, tokens and time only, never your words.") {
                    HStack(spacing: 10) {
                        PillButton(title: "Copy") { controls.copyCostLog() }
                        PillButton(title: "Clear") { controls.clearCostLog() }
                    }
                }
            }
            SectionLabel(text: "Tool Gate log")
            Card {
                toggleRow("Record Tool Gate Log",
                          "Keeps the last 50 requests in memory: language, route, route source, router route and confidence, tier, tokens and timing. Never your words.",
                          isOn: controls.recordingLog, set: { controls.setRecordingLog($0) })
                RowDivider()
                SettingRow(title: "Log entries", detail: "\(controls.logCount) recorded. Copy pastes a Markdown table you can share.") {
                    HStack(spacing: 10) {
                        PillButton(title: "Copy") { controls.copyLog() }
                        PillButton(title: "Clear") { controls.clearLog() }
                    }
                }
            }
            if let message = controls.message {
                AccountNotice(message: message, isError: controls.messageIsError)
            }
        }
        .onAppear { controls.refresh() }
    }

    /// One feature's model picker, with its price per million tokens.
    private func modelRow(_ feature: ModelFeature) -> some View {
        let choices = ModelCatalog.choices(for: feature)
        let selected = controls.models[feature] ?? ModelCatalog.defaultChoice(for: feature).id
        let current = choices.first { $0.id == selected } ?? choices[0]
        return SettingRow(title: feature.title,
                          detail: "\(current.id) · $\(String(format: "%g", current.inputPerMillion)) in / $\(String(format: "%g", current.outputPerMillion)) out per million tokens") {
            Picker("", selection: Binding(get: { selected }, set: { controls.selectModel($0, for: feature) })) {
                ForEach(choices) { choice in
                    Text(choice.name + (choice == ModelCatalog.defaultChoice(for: feature) ? " (default)" : "")).tag(choice.id)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            .disabled(choices.count < 2)
            .accessibilityLabel("\(feature.title) model")
        }
    }

    /// One provider key: name, use, status (last 4 characters only) and
    /// Paste & Save / Test / Remove. Keys are never typed or shown here.
    private func keyRow(_ slot: DeveloperKeySlot) -> some View {
        let isSet = controls.hasKey(slot)
        let result = controls.keyTest[slot]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(slot.title)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(.white)
                    Text(slot.usage)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                StatusBadge(ready: isSet, readyText: controls.keyStatus[slot] ?? "Set ✓", missingText: "Not set")
            }
            HStack(spacing: 10) {
                PillButton(title: "Paste & Save", prominent: !isSet, symbol: "doc.on.clipboard") { controls.pasteAndSave(slot) }
                PillButton(title: controls.keyTesting.contains(slot) ? "Testing…" : "Test") { controls.testKey(slot) }
                    .disabled(!isSet || controls.keyTesting.contains(slot))
                if isSet {
                    PillButton(title: "Remove") { controls.removeKey(slot) }
                }
                if let result {
                    Text(result.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(result.isOK ? Color(red: 0.52, green: 0.88, blue: 0.72) : Color(red: 1, green: 0.65, blue: 0.59))
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        SettingRow(title: title, detail: detail) {
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch).labelsHidden()
                .accessibilityLabel(title)
        }
    }
}
#endif
