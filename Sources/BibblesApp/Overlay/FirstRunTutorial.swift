import AppKit
import AVFoundation
import SwiftUI

enum TutorialLaunchPolicy {
    static let pendingStepKey = "bibbles.setup.pendingStep"

    static func claimFirstPresentation(defaults: UserDefaults = .standard) -> Bool {
        // A screen-permission restart resumes setup without onboarding existing users again.
        if let value = defaults.object(forKey: pendingStepKey) as? Int,
           TutorialStep(rawValue: value) != nil { return true }
        let key = "didShowGettingStarted.v1"
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        return true
    }
}

enum TutorialStep: Int, CaseIterable {
    case welcome, screen, accessibility, microphone, ready

    var title: String {
        switch self {
        case .welcome: return "Hey, I’m Bibbles."
        case .screen: return "Can you open my eyes?"
        case .accessibility: return "Let’s put your words to work."
        case .microphone: return "One last thing. Your voice."
        case .ready: return "See you at the notch."
        }
    }

    func isGranted(_ status: PermissionSnapshot) -> Bool {
        switch self {
        case .screen: return status.screenRecording
        case .accessibility: return status.accessibility
        case .microphone: return status.microphone == .authorized
        default: return true
        }
    }

    func automaticNext(status: PermissionSnapshot, verifiedFrame: Bool) -> TutorialStep? {
        switch self {
        case .screen where status.screenRecording && verifiedFrame: return .accessibility
        case .accessibility where status.accessibility: return .microphone
        case .microphone where status.microphone == .authorized: return .ready
        default: return nil
        }
    }
}

enum TutorialGeometry {
    static let size = CGSize(width: 390, height: 350)

    static func size(for step: TutorialStep) -> CGSize {
        let height: CGFloat
        switch step {
        case .welcome: height = 245
        case .screen, .accessibility: height = 350
        case .microphone: height = 270
        case .ready: height = 300
        }
        return CGSize(width: size.width, height: height)
    }

    static func frame(in screen: CGRect, pointer: CGPoint, size: CGSize = size) -> CGRect {
        let safe = screen.insetBy(dx: 18, dy: 18)
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        let nearby = CGPoint(x: pointer.x + 32, y: pointer.y - height / 2)
        return CGRect(x: min(max(nearby.x, safe.minX), safe.maxX - width),
                      y: min(max(nearby.y, safe.minY), safe.maxY - height), width: width, height: height)
    }

    static func avatar(in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + 24, y: panel.maxY - 88, width: 64, height: 64)
    }
}

@MainActor
private final class TutorialState: ObservableObject {
    @Published var step = TutorialStep.welcome
    @Published var status = PermissionService.snapshot()
    @Published var waiting = false
    @Published var celebrating = false
    @Published var captureNeedsRestart = false
    @Published var guidedRow = false
    var verifiedFrame = false
}

private final class TutorialPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FirstRunTutorialController: NSObject, NSWindowDelegate {
    private var window: TutorialPanel?
    private let state = TutorialState()
    private let marks = TargetHighlightController()
    private var polling: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var generation = UUID()
    private var lastProbe = Date.distantPast
    private var settingsOpened = false
    private let onSignIn: () -> Void
    private let onFinish: () -> Void
    private let onTryTyping: () -> Void
    private let onVisibilityChanged: () -> Void

    init(onSignIn: @escaping () -> Void, onFinish: @escaping () -> Void = {},
         onTryTyping: @escaping () -> Void = {}, onVisibilityChanged: @escaping () -> Void = {}) {
        self.onSignIn = onSignIn
        self.onFinish = onFinish
        self.onTryTyping = onTryTyping
        self.onVisibilityChanged = onVisibilityChanged
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        generation = UUID()
        state.step = (UserDefaults.standard.object(forKey: TutorialLaunchPolicy.pendingStepKey) as? Int)
            .flatMap(TutorialStep.init(rawValue:)) ?? .welcome
        state.status = PermissionService.snapshot()
        state.verifiedFrame = false
        state.waiting = false
        state.celebrating = false
        state.captureNeedsRestart = false
        state.guidedRow = false
        lastProbe = .distantPast
        settingsOpened = false
        persistStep()
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let panel = TutorialPanel(contentRect: TutorialGeometry.frame(in: screen.visibleFrame, pointer: pointer,
                                  size: TutorialGeometry.size(for: state.step)),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Set up Bibbles"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FirstRunTutorialView(state: state,
            onPrimary: { [weak self] in self?.primaryAction() },
            onLater: { [weak self] in self?.skipStep() },
            onClose: { [weak self] in self?.hide() },
            onSignIn: { [weak self] in self?.handoff { self?.onSignIn() } },
            onTryTyping: { [weak self] in self?.handoff { self?.onTryTyping() } }))
        window = panel
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        onVisibilityChanged()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screensChanged() }
            }
        startPolling()
    }

    func hide() {
        generation = UUID()
        polling?.cancel(); polling = nil
        transitionTask?.cancel(); transitionTask = nil
        handoffTask?.cancel(); handoffTask = nil
        marks.hide()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        UserDefaults.standard.removeObject(forKey: TutorialLaunchPolicy.pendingStepKey)
        onVisibilityChanged()
    }

    func windowWillClose(_ notification: Notification) { hide() }

    func invalidateGuidance() {
        guard isVisible, state.step == .accessibility else { return }
        marks.hide()
        state.guidedRow = false
        lastProbe = Date()
    }

    private func persistStep() { UserDefaults.standard.set(state.step.rawValue, forKey: TutorialLaunchPolicy.pendingStepKey) }

    private func move(to step: TutorialStep) {
        marks.hide()
        state.step = step
        state.waiting = false
        state.celebrating = false
        state.guidedRow = false
        state.captureNeedsRestart = false
        settingsOpened = false
        lastProbe = .distantPast
        persistStep()
        resizeForStep()
    }

    private func resizeForStep() {
        guard let panel = window, let screen = panel.screen ?? NSScreen.main else { return }
        let size = TutorialGeometry.size(for: state.step)
        let pointer = CGPoint(x: panel.frame.minX - 32, y: panel.frame.maxY - size.height / 2)
        let frame = TutorialGeometry.frame(in: screen.visibleFrame, pointer: pointer, size: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func startPolling() {
        let run = generation
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == run, self.window != nil else { return }
                await self.poll(run: run)
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }

    private func poll(run: UUID) async {
        state.status = PermissionService.snapshot()
        if !state.status.screenRecording { state.verifiedFrame = false }
        if state.step == .accessibility,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.systempreferences" {
            marks.hide()
            state.guidedRow = false
        }
        guard transitionTask == nil, state.step != .welcome, state.step != .ready else { return }
        if state.step == .screen, state.status.screenRecording, !state.verifiedFrame,
           Date().timeIntervalSince(lastProbe) > 3 {
            lastProbe = Date()
            do {
                // Local, ephemeral frame verification. No screenshot is stored or sent to AI.
                let frame = try await ScreenCaptureService().captureDisplayOverview(maximumLongEdgePixels: 640)
                guard !Task.isCancelled, generation == run, state.step == .screen else { return }
                state.verifiedFrame = frame.image.width > 0 && frame.image.height > 0
                state.captureNeedsRestart = !state.verifiedFrame
            } catch {
                guard !Task.isCancelled, generation == run else { return }
                state.captureNeedsRestart = true
            }
            state.status = PermissionService.snapshot()
            if !state.status.screenRecording { state.verifiedFrame = false }
        }
        guard !Task.isCancelled, generation == run else { return }
        if let next = state.step.automaticNext(status: state.status, verifiedFrame: state.verifiedFrame) {
            celebrateAndAdvance(to: next, run: run)
        } else if state.step == .accessibility, settingsOpened, state.status.screenRecording,
                  Date().timeIntervalSince(lastProbe) > 3 {
            lastProbe = Date()
            await guideSettingsRow(run: run)
        }
    }

    private func celebrateAndAdvance(to next: TutorialStep, run: UUID) {
        state.waiting = false
        state.celebrating = true
        if state.step == .accessibility, let frame = window?.frame {
            // Known app-owned geometry: demonstrate on our companion, never on guessed UI.
            marks.showGuidance([DoodleMark(shape: .circle, rect: TutorialGeometry.avatar(in: frame),
                tone: .teal, label: "Right here.")], durationNanoseconds: 1_300_000_000)
        }
        transitionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_100_000_000) } catch { return }
            guard let self, self.generation == run else { return }
            // Recheck revocation during the celebration before advancing.
            self.state.status = PermissionService.snapshot()
            if !self.state.status.screenRecording { self.state.verifiedFrame = false }
            guard self.state.step.automaticNext(status: self.state.status, verifiedFrame: self.state.verifiedFrame) == next else {
                self.state.celebrating = false
                self.transitionTask = nil
                return
            }
            self.move(to: next)
            self.transitionTask = nil
        }
    }

    private func guideSettingsRow(run: UUID) async {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.systempreferences" else { marks.hide(); return }
        let pid = app.processIdentifier
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        guard let bounds = await TutorialSettingsTarget.windowBounds(pid: pid, top: top) else { return }
        do {
            let frame = try await ScreenCaptureService().captureDisplayOverview(
                cursor: CGPoint(x: bounds.midX, y: bounds.midY), maximumLongEdgePixels: 1600)
            let words = try await VisionOCRService().recognizeText(in: frame.image, accurate: true)
            guard !Task.isCancelled, generation == run, state.step == .accessibility,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let rect = TutorialSettingsTarget.bibblesRow(words: words, descriptor: frame.descriptor, window: bounds) else { return }
            marks.showGuidance([DoodleMark(shape: .rectangle, rect: rect, tone: .teal,
                label: "Enable Bibbles on this row")], durationNanoseconds: 2_500_000_000)
            state.guidedRow = true
        } catch { /* Keep the textual guide if Settings cannot be read confidently. */ }
    }

    private func primaryAction() {
        guard !state.celebrating else { return }
        switch state.step {
        case .welcome: move(to: .screen)
        case .screen:
            state.waiting = true
            _ = PermissionService.requestScreenRecording()
            PermissionService.openScreenRecordingSettings()
        case .accessibility:
            state.waiting = true
            settingsOpened = true
            PermissionService.requestAccessibilityPrompt()
            PermissionService.openAccessibilitySettings()
        case .microphone:
            state.waiting = true
            if state.status.microphone == .notDetermined {
                Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .ready: handoff { [weak self] in self?.onFinish() }
        }
    }

    private func skipStep() {
        transitionTask?.cancel(); transitionTask = nil
        if let next = TutorialStep(rawValue: state.step.rawValue + 1) { move(to: next) }
    }

    private func handoff(completion: @escaping () -> Void) {
        guard handoffTask == nil, let panel = window else { return }
        polling?.cancel()
        marks.hide()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            if !reduceMotion, let screen = panel.screen {
                panel.animator().setFrameOrigin(CGPoint(x: screen.frame.midX - panel.frame.width / 2,
                                                       y: screen.visibleFrame.maxY - panel.frame.height + 16))
            }
        }
        handoffTask = Task { [weak self] in
            if !reduceMotion { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled, let self else { return }
            self.handoffTask = nil
            self.hide()
            completion()
        }
    }

    private func screensChanged() {
        marks.hide()
        guard let panel = window, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrame(TutorialGeometry.frame(in: screen.visibleFrame,
            pointer: CGPoint(x: panel.frame.minX - 32, y: panel.frame.midY),
            size: TutorialGeometry.size(for: state.step)), display: true)
    }
}

/// Reads only the foreground Settings window and exact OCR evidence. No inferred switch coordinates.
enum TutorialSettingsTarget {
    static func windowBounds(pid: pid_t, top: CGFloat) async -> CGRect? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let rect = windows.lazy.compactMap { window -> CGRect? in
                    guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                          (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                          let values = window[kCGWindowBounds as String] as? [String: Any],
                          let raw = CGRect(dictionaryRepresentation: values as CFDictionary), raw.width > 100, raw.height > 100 else { return nil }
                    return CGRect(x: raw.minX, y: top - raw.maxY, width: raw.width, height: raw.height)
                }.first
                continuation.resume(returning: rect)
            }
        }
    }

    static func bibblesRow(words: [OCRObservation], descriptor: CaptureDescriptor, window: CGRect) -> CGRect? {
        let candidates = words.filter { $0.confidence >= 0.8 && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "bibbles" }
            .compactMap { try? CoordinateMapper.globalQuartzRect(for: $0.normalizedRect, descriptor: descriptor) }
            .filter { window.contains($0) }
        return candidates.count == 1 ? candidates.first : nil
    }
}

private struct FirstRunTutorialView: View {
    @ObservedObject var state: TutorialState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onPrimary: () -> Void
    let onLater: () -> Void
    let onClose: () -> Void
    let onSignIn: () -> Void
    let onTryTyping: () -> Void
    @State private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TutorialCompanion(blind: state.step == .screen && !state.celebrating,
                                  waiting: state.waiting, celebrating: state.celebrating)
                    .frame(width: 64, height: 64)
                    .accessibilityLabel(state.celebrating ? "Permission enabled" : "Bibbles companion")
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        ForEach(TutorialStep.allCases, id: \.rawValue) { step in
                            Capsule().fill(step.rawValue <= state.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                                .frame(width: step == state.step ? 16 : 5, height: 5)
                        }
                    }
                    .accessibilityLabel("Setup step \(state.step.rawValue + 1) of 5")
                    Text(state.celebrating ? successTitle : state.step.title)
                        .font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 5).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close setup")
            }
            Text(copy).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).id(state.step).transition(.opacity)
            details
            Spacer(minLength: 0)
            HStack {
                if state.step != .welcome && state.step != .ready {
                    Button("Later", action: onLater).buttonStyle(.plain).foregroundStyle(.secondary)
                } else if state.step == .ready {
                    Button("Sign in", action: onSignIn).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onPrimary) {
                    HStack(spacing: 7) {
                        if state.celebrating { Image(systemName: "checkmark") }
                        Text(primaryTitle)
                    }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(state.celebrating).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: TutorialGeometry.size.width, height: TutorialGeometry.size(for: state.step).height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state.step)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.celebrating)
        .onExitCommand(perform: onClose)
    }

    private var copy: String {
        if state.celebrating { return state.step == .accessibility ? "A little highlight, right on your screen. Let’s keep going." : "That’s it. We’re one step closer." }
        switch state.step {
        case .welcome: return "Your work, with a little company. I can explain what you see, guide your next move, and turn thoughts into text. Let’s wake me up."
        case .screen: return "I can’t see your screen yet. Enable Bibbles in Screen Recording so I can understand what you point at."
        case .accessibility: return state.status.screenRecording ? "Awesome, I can see. Enable Accessibility so I can read selections, type for you, and help with Mac actions." : "Enable Accessibility so I can read selections, type for you, and help with Mac actions."
        case .microphone: return "Let me hear you when you hold the shortcut. Prefer typing? You can skip this."
        case .ready: return "Hold Control + Option, ask a question, then release. I’ll be right here whenever you need a hand."
        }
    }

    @ViewBuilder private var details: some View {
        switch state.step {
        case .welcome:
            Label("A quick setup. Always your choice.", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
        case .screen, .accessibility:
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    BibblesBrandMark(size: 18)
                    Text("Bibbles").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 30, height: 18)
                        .overlay(Circle().fill(.white).frame(width: 14, height: 14).offset(x: -6))
                        .accessibilityHidden(true)
                }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Text(state.captureNeedsRestart ? "If macOS asks, quit and reopen. I’ll resume here."
                     : state.guidedRow ? "I’ve highlighted your Bibbles row. Turn its switch on."
                     : "Look for this row in Settings. Turn its switch on.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Your privacy", action: { showPrivacy.toggle() }).buttonStyle(.link).font(.caption)
                    .popover(isPresented: $showPrivacy) {
                        Text(state.step == .screen
                             ? "Setup checks one local frame and discards it. Screen questions may send relevant screenshots to Bibbles’ cloud AI. Bibbles does not continuously record your screen."
                             : "Accessibility enables selected text, dictation, and supported Mac actions. Highlights are native overlays and don’t require this permission. You can revoke access in System Settings.")
                            .font(.callout).padding(18).frame(width: 300)
                    }
            }
        case .microphone:
            Text("Voice audio is sent for transcription only when you invoke voice input.")
                .font(.caption).foregroundStyle(.secondary)
        case .ready:
            HStack(spacing: 8) {
                Text("⌃ Control").padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                Text("⌥ Option").padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                Spacer()
                Button("Try typing", action: onTryTyping).buttonStyle(.link)
            }.font(.system(size: 12, weight: .medium))
            Text("fn + Control to dictate · Escape to dismiss").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var successTitle: String {
        switch state.step {
        case .screen: return "I can see!"
        case .accessibility: return "Look what we can do."
        default: return "Loud and clear."
        }
    }

    private var primaryTitle: String {
        if state.celebrating { return "Connected" }
        switch state.step {
        case .welcome: return "Let’s get set up"
        case .screen: return state.waiting ? "Open settings again" : "Open Screen Recording"
        case .accessibility: return state.waiting ? "Open settings again" : "Open Accessibility"
        case .microphone: return state.status.microphone == .notDetermined ? "Enable microphone" : "Open Microphone Settings"
        case .ready: return "Let’s go"
        }
    }
}

private struct TutorialCompanion: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let blind: Bool
    let waiting: Bool
    let celebrating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion ? 0 : sin(phase * 2) * (waiting ? 1.5 : 0.7)
            ZStack {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(LinearGradient(colors: [.cyan.opacity(0.7), .blue.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.5)))
                    .shadow(color: .cyan.opacity(0.18), radius: 8, y: 3)
                VStack(spacing: 7) {
                    HStack(spacing: 12) {
                        ForEach(0..<2) { _ in
                            Capsule().fill(Color(red: 0.07, green: 0.16, blue: 0.25))
                                .frame(width: blind ? 9 : 5, height: blind ? 2 : 8)
                        }
                    }
                    if celebrating {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.07, green: 0.16, blue: 0.25))
                    } else {
                        Path { path in
                            path.move(to: CGPoint(x: 1, y: 1))
                            path.addQuadCurve(to: CGPoint(x: 19, y: 1), control: CGPoint(x: 10, y: 12))
                        }.stroke(Color(red: 0.07, green: 0.16, blue: 0.25), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: 20, height: 8)
                    }
                }
                if celebrating {
                    Image(systemName: "sparkle").font(.system(size: 14)).foregroundStyle(.white)
                        .offset(x: 25, y: -25)
                }
            }.offset(y: breath)
        }.accessibilityElement(children: .ignore)
    }
}
