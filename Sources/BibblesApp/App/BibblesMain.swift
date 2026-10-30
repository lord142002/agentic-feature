import AppKit
import AVFoundation
import Combine

@main
enum BibblesMain {
    static func main() {
        // Developer-only: hybrid router checks without XCTest (no network).
        if CommandLine.arguments.contains("--router-self-test") { RouterSelfTest.runAndExit() }
        let application = NSApplication.shared
        let delegate = BibblesApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class BibblesApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let interaction = InteractionModel()
    private var accountObserver: AnyCancellable?
    /// "Read the selected text, then send" steps. Tracked so Escape / Cancel
    /// stops them before anything is sent.
    private var contextPreparationTask: Task<Void, Never>?
    private var contextPreparationID = UUID()
    private let voiceMeter = VoiceActivityMeter()
    private let hotkeys = GlobalHotkeyMonitor()
    private let latency = LatencyRecorder()
    private let screenLatency = LatencyRecorder()
    private let configuration = BibblesConfiguration.load()
    private let dictationPreferences = DictationPreferences()
    /// Monthly AI asks and deep tasks, shown in the Welcome window.
    private let usageMeter = UsageMeter()
    private let correctionStore = SpeechCorrectionStore()
    private let correctionObservations = CorrectionObservationStore()
    private let usageMetrics = LocalUsageMetrics()
    private let textInserter = FocusedTextInserter()
    private let focusedContextReader = FocusedContextReader()
    private let intentRouter = IntentRouter()
    private let screenCapture = ScreenCaptureService()
    private let ocr = VisionOCRService()
    private let targetHighlight = TargetHighlightController()
    private let circleFocus = CircleFocusController()
    private var focusCaptureTask: Task<ScreenCaptureResult, Error>?
    private var focusPoint: CGPoint?
    private var focusFinishedSpeech = false
    private lazy var voiceReply = VoiceReplyController()
    private var shouldSpeakNextAnswer = false {
        didSet {
            guard oldValue != shouldSpeakNextAnswer else { return }
            // Which code changed it (function names only), to trace answers
            // that should have been spoken but weren't.
            let callers = Thread.callStackSymbols.dropFirst(2).prefix(3).map { line -> String in
                let name = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? "?"
                return String(name.prefix(90))
            }
            Diagnostics.log("speak_flag", ["to": shouldSpeakNextAnswer, "by": callers.joined(separator: "<")])
        }
    }
    /// An answer card waiting for its voice to start, and which speech it waits for.
    private var heldAnswer: (show: () -> Void, voice: UUID)?
    private var heldAnswerTimeout: Task<Void, Never>?
    /// The speech whose wait already timed out: the rest of that answer shows at once.
    private var stoppedWaitingFor: UUID?
    private var voiceRepliesEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "bibbles.voiceRepliesEnabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "bibbles.voiceRepliesEnabled") }
    }
    private lazy var overlay = FloatingPanelController(
        model: interaction,
        meter: voiceMeter,
        voiceReply: voiceReply,
        onOpenChat: { [weak self] in
            self?.openChat()
        },
        onClose: { [weak self] in self?.dismissPanels() },
        onVisibilityChanged: { [weak self] in self?.updateEscapeCapture() },
        onCancel: { [weak self] in self?.cancelCurrentOperation() },
        onRetry: { [weak self] in self?.retryLastOperation() },
        onUseTranscriptAnyway: { [weak self] in self?.useTranscriptAnyway() },
        onToggleVoice: { [weak self] answer in self?.toggleVoice(answer) },
        onInsert: { [weak self] answer in self?.typeAnswer(answer, into: self?.lastExternalApp) }
    )
    private lazy var composer = TextComposerController()
    private lazy var visualExplanation = VisualExplanationController(
        onClose: { [weak self] in self?.dismissPanels() },
        onVisibilityChanged: { [weak self] in self?.updateEscapeCapture() }
    )
    private lazy var chatStore = ChatConversationStore()
    private lazy var chatPanel = ChatPanelController(
        store: chatStore,
        onDismiss: { [weak self] in self?.closeChatPanel() },
        onEscape: { [weak self] in self?.dismissPanels() },
        onVisibilityChanged: { [weak self] in self?.updateEscapeCapture() },
        onSubmit: { [weak self] text, documents, searchWeb in
            self?.submitFromChat(text, documents: documents, searchWeb: searchWeb) ?? false
        }
    )
    /// Drops down from the notch with the tasks Bibbles has finished.
    private lazy var taskHistory: TaskHistoryPanelController = TaskHistoryPanelController(
        store: chatStore,
        pointerIsNearNotch: { [weak self] in
            guard let self else { return false }
            return self.hotkeys.isPointerNearNotch()
                || (self.notchPill.isVisible && self.notchPill.frame.insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation))
        },
        onOpenItem: { [weak self] item in
            guard let self else { return }
            #if BIBBLES_DEVELOPER
            // A Files agent run that can still be undone: show its Done · Undo card.
            if let session = AgentUndoRegistry.shared.session(forAnswer: item.answer) {
                self.agentPanel.show(session)
                return
            }
            #endif
            if self.chatStore.conversations.contains(where: { $0.id == item.conversationID }) {
                self.chatStore.selectedID = item.conversationID
            }
            self.openChat()
        },
        onOpenChat: { [weak self] in self?.openChat() },
        onNewChat: { [weak self] in
            self?.chatStore.createConversation()
            self?.openChat()
        },
        onOpenSettings: { [weak self] in self?.openSettings() },
        onShowHelp: { [weak self] in self?.showGettingStarted() },
        onQuit: { [weak self] in self?.quit() },
        onVisibilityChanged: { [weak self] in self?.updateEscapeCapture() }
    )
    #if BIBBLES_DEVELOPER
    private lazy var agentPanel = AgentPanelController()
    /// The agent task on screen, for "stop" / "continue" said by voice.
    private weak var activeScreenSession: ScreenAgentSession?
    private weak var activeFilesSession: FilesAgentSession?
    #endif
    /// The "Welcome to Bibbles" guide (first launch, the notch's info button, Help).
    private lazy var welcomeWindow: WelcomeWindowController = WelcomeWindowController(
        onSetUpPermissions: { [weak self] in self?.showPermissionStatus() },
        onSignIn: { [weak self] in self?.settingsWindow.show(section: .account) }
    )
    private lazy var firstRunTutorial = FirstRunTutorialController(
        onSignIn: { [weak self] in self?.settingsWindow.show(section: .account) },
        onFinish: { [weak self] in
            ProductAnalytics.shared.track(.tutorialCompleted)
            guard let self, self.notchHistoryEnabled else { return }
            self.notchPill.show()
        },
        onTryTyping: { [weak self] in self?.openComposer() },
        onVisibilityChanged: { [weak self] in self?.updateEscapeCapture() }
    )
    /// The Settings window (from the notch panel's gear or the menu).
    private lazy var settingsWindow: SettingsWindowController = SettingsWindowController(actions: SettingsActions(
        setNotchHistory: { [weak self] on in
            guard let self else { return }
            self.notchHistoryEnabled = on
            if on { self.notchPill.show() } else { self.taskHistory.hide(); self.notchPill.hide() }
            self.updateMenuBarIcon()
        },
        setMenuBarIcon: { [weak self] on in
            UserDefaults.standard.set(on, forKey: "bibbles.showMenuBarIcon")
            self?.updateMenuBarIcon()
        },
        setVoiceReplies: { [weak self] on in
            guard let self else { return }
            self.voiceRepliesEnabled = on
            if !on { self.shouldSpeakNextAnswer = false; self.voiceReply.stop() }
        },
        previewVoice: { [weak self] voice in
            guard let self else { return nil }
            // Saved previews play instantly; new ones are fetched once and saved.
            if case .failure(let error) = await self.voiceReply.playPreview(voice: voice ?? OpenRouterSpeech.englishVoice) {
                if VoiceReplyController.isCancellation(error) { return nil }
                return error.localizedDescription
            }
            return nil
        },
        testVoice: { [weak self] in self?.testVoice() },
        editVocabulary: { [weak self] in self?.configureVocabulary() },
        teachCorrection: { [weak self] in self?.teachCorrection() },
        reportCorrection: { [weak self] in self?.reportDictationCorrection() },
        clearChatHistory: { [weak self] in self?.clearChatHistory() },
        showPermissions: { [weak self] in self?.showPermissionStatus() },
        showGettingStarted: { [weak self] in self?.showGettingStarted() },
        prefetchVoicePreviews: { [weak self] in self?.voiceReply.prefetchPreviews() }
    ))
    /// The Bibbles bar that wraps the notch; hovering it opens the task history.
    private lazy var notchPill: NotchPillController = NotchPillController(
        store: chatStore,
        activity: { [weak self] in self?.notchActivity },
        interactionActive: { [weak self] in
            guard let self else { return false }
            return self.speechTurnIsActive || self.overlay.isVisible || self.composer.isVisible
                || self.chatPanel.isVisible || self.voiceReply.isPlaying
        },
        onHover: { [weak self] in self?.showTaskHistoryFromNotch() },
        onHidden: { [weak self] in self?.taskHistory.hideImmediately() },
        // Clicking only opens it: hovering usually opened it a moment
        // before, and a toggle would close it again.
        onClick: { [weak self] in self?.showTaskHistoryFromNotch() }
    )
    /// What Bibbles is doing, shown on the notch bar (nil when idle).
    private var notchActivity: String? {
        if speechTurnIsActive { return activeSpeechMode == .dictation ? "Dictating" : "Listening" }
        if voiceReply.isPlaying { return "Speaking" }
        if chatStore.isSending || chatStore.activityMessage != nil { return "Thinking" }
        if case .working = interaction.state { return "Thinking" }
        return nil
    }
    private var notchHistoryEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "bibbles.notchHistoryEnabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "bibbles.notchHistoryEnabled") }
    }
    /// Speech to text is uploaded to the authenticated Worker after release.
    private lazy var speech = SpeechPipeline(
        capture: MicrophoneCapture(),
        stream: SpeechToText.makeStream(configuration: configuration)
    )
    private var speechStartTask: Task<Bool, Never>?
    private var statusItem: NSStatusItem?
    private var dismissTask: Task<Void, Never>?
    private var selfTestContinuation: CheckedContinuation<Void, Never>?
    private var selfTestRunning = false
    private var transcriptVisibleThisTurn = false
    private var activeSpeechMode: SpeechMode = .command
    private var liveDictationSession: LiveFocusedTextSession?
    private var reopenChatWhenNearNotch = false
    private var latestPartialTranscript = ""
    private var lastFailedSpeechMode: SpeechMode = .command
    private var dictationBeganAt: Date?
    private var dictationSpokenSeconds: TimeInterval?
    private var pointedLocation: CGPoint?
    private var screenQuestionTask: Task<Void, Never>?
    /// The step-by-step screen walkthrough in progress (drawing timer).
    private var walkthroughTask: Task<Void, Never>?
    /// "Ok, let me think first" plays once per spoken question.
    private var thinkingCuePlayed = true
    private var sendingObserver: AnyCancellable?
    /// Changes when a walkthrough stops, so late speech callbacks draw nothing.
    private var walkthroughID = UUID()
    private var walkthroughMarks: [DoodleMark?] = []
    private var walkthroughSays: [String] = []
    private var walkthroughShownThrough = -1
    private var screenQuestionGeneration = UUID()
    private var speechTurnIsActive = false
    private var pendingVisualQuestion: String?
    private var activeScreenChatID: UUID?
    /// The last app the user worked in other than Bibbles; answers are typed here.
    private var lastExternalApp: NSRunningApplication?
    /// Set while a "write …" request is generating; the answer is typed into this app.
    private var pendingWriteTarget: NSRunningApplication?
    /// When the pending write replaces earlier text: the text to find and
    /// select first (nil when the user's highlight is replaced instead).
    private var pendingEdit: PendingEdit?
    /// The request behind the pending write, kept in Bibbles' work memory.
    private var pendingWriteRequest = ""
    private struct PendingEdit {
        let original: String?
    }
    /// Where the highlighted text is on screen, found while Claude answers,
    /// so Bibbles can mark exactly what it is explaining.
    private var pendingSelectionMark: Task<CGRect?, Never>?
    private var appActivationObserver: NSObjectProtocol?
    private let formScanner = FormFieldScanner()
    /// How long after a screenshot its on-screen marks may still be drawn.
    private static let markMaximumAge: TimeInterval = 30
    /// Walkthrough answers are longer to write. The display must be unchanged
    /// and nothing scrolled since the capture, so the marks still line up.
    private static let walkthroughMarkAge: TimeInterval = 120
    private lazy var formFiller = FormFieldFiller(inserter: textInserter)
    private var formFillTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProductAnalytics.shared.start(userID: AccountSession.shared.userID)
        observeAccountChanges()
        updateMenuBarIcon()
        configureInteractions()
        trackExternalApps()
        hotkeys.start()
        #if BIBBLES_DEVELOPER
        DeveloperKeychain.migrateLegacyRouterKey()
        #endif
        let environment = ProcessInfo.processInfo.environment
        let isSelfTest = environment["BIBBLES_STT_SELF_TEST"] == "1"
            || environment["BIBBLES_SCREEN_SELF_TEST"] == "1"
            || environment["BIBBLES_VISION_SELF_TEST"] == "1"
        if !isSelfTest {
            if ProcessInfo.processInfo.arguments.contains("--setup-tutorial") { showSetupTutorial() }
            else { showGettingStartedIfNeeded() }
        }
        if ProcessInfo.processInfo.environment["BIBBLES_STT_SELF_TEST"] == "1" {
            Task { await runAcousticSelfTest() }
        }
        if ProcessInfo.processInfo.environment["BIBBLES_SCREEN_SELF_TEST"] == "1" {
            Task { await runScreenSelfTest() }
        }
        if ProcessInfo.processInfo.environment["BIBBLES_VISION_SELF_TEST"] == "1" {
            Task { await runVisionSelfTest() }
        }
    }

    /// Opening Bibbles again while it is running (Finder, Spotlight,
    /// Launchpad) brings the notch bar back.
    /// Opening Bibbles again (Finder, Spotlight, Launchpad) brings the notch
    /// bar back and opens Settings, since there's no menu-bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if notchHistoryEnabled { notchPill.show() }
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        circleFocus.stop()
        focusCaptureTask?.cancel()
        hotkeys.stop()
        voiceReply.stop()
        dismissTask?.cancel()
        Task { await speech.shutdown() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == AccountSession.callbackURL.scheme }) else { return }
        Task { @MainActor in
            if BillingAPI.isReturnURL(url) {
                settingsWindow.show(section: .account)
                await AccountSession.shared.handleBillingReturn(url)
                return
            }
            await AccountSession.shared.handleCallback(url)
            settingsWindow.show(section: .account)
        }
    }

    private func configureInteractions() {
        targetHighlight.onDisplayChange = { [weak self] in self?.stopWalkthrough() }
        circleFocus.onDragBegan = { [weak self] in
            guard let self else { return }
            self.screenQuestionTask?.cancel()
            self.screenQuestionTask = nil
            self.screenQuestionGeneration = UUID()
            if let id = self.activeScreenChatID { self.chatStore.cancelScreenQuestion(in: id) }
            self.activeScreenChatID = nil
            self.overlay.hide()
            self.targetHighlight.hide()
        }
        circleFocus.onSelection = { [weak self] selection in self?.captureFocus(selection) }
        circleFocus.onVisibilityChanged = { [weak self] in self?.updateEscapeCapture() }
        circleFocus.start()
        hotkeys.onFocusModifiersChanged = { [weak self] flags in self?.circleFocus.modifiersChanged(flags) }
        composer.onVisibilityChanged = { [weak self] in self?.updateEscapeCapture() }
        composer.onEscape = { [weak self] in self?.dismissPanels() }
        speech.onAudioFrame = { [weak self] frame in self?.voiceMeter.receive(frame) }
        hotkeys.onAction = { [weak self] action in self?.handle(action) }
        hotkeys.onDesktopScroll = { [weak self] in
            // Scrolling moves what the walkthrough marks point at. Clicks and
            // typing (pausing a video, say) leave the drawing in place.
            guard let self, self.targetHighlight.isShowingWalkthrough || self.walkthroughTask != nil else { return }
            Diagnostics.log("walkthrough", ["event": "stopped_by_scroll"])
            self.stopWalkthrough()
        }
        hotkeys.onDesktopInteraction = { [weak self] in
            if self?.firstRunTutorial.isVisible == true { self?.firstRunTutorial.invalidateGuidance() }
            guard let self, self.visualExplanation.isVisible, self.visualExplanation.player.hasScreenGuidance else { return }
            self.visualExplanation.player.invalidateScreenContext()
            self.targetHighlight.hide()
        }
        hotkeys.onPointerNearNotch = { [weak self] in
            guard let self, self.notchHistoryEnabled, !self.chatPanel.isVisible,
                  !self.taskHistory.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
            self.reopenChatWhenNearNotch = false
            self.notchPill.requestHover()
        }
        if notchHistoryEnabled {
            notchPill.show()
        }
        // A spoken answer's card waits for its voice (see showInSyncWithVoice).
        voiceReply.onSpeechStarted = { [weak self] in self?.releaseHeldAnswer() }
        chatStore.onAssistantReply = { [weak self] response, sources in
            guard let self else { return }
            let display = sources.isEmpty ? response : response + "\n\nSources:\n" + sources.map {
                "\($0.title): \($0.url.absoluteString)"
            }.joined(separator: "\n")
            if let target = self.pendingWriteTarget {
                self.pendingWriteTarget = nil
                self.shouldSpeakNextAnswer = false
                self.voiceReply.stop()
                self.interaction.rememberAnswer(response)
                self.typeAnswer(response, into: target)
                return
            }
            if self.shouldSpeakNextAnswer {
                self.voiceReply.accept(response, final: true)
                self.shouldSpeakNextAnswer = false
            }
            // Answers that needed the advanced model count as deep tasks.
            if self.chatStore.lastReplyModel == ClaudeAPI.smartModel { self.usageMeter.recordDeepTask() }
            self.interaction.rememberAnswer(display)
            if let selection = self.pendingSelectionMark {
                self.pendingSelectionMark = nil
                let preparation = self.beginContextPreparation()
                self.contextPreparationTask = Task { @MainActor [weak self] in
                    defer { selection.cancel() }
                    let rect = await withTaskCancellationHandler {
                        await selection.value
                    } onCancel: { selection.cancel() }
                    guard let self, self.isCurrentContextPreparation(preparation), let rect else { return }
                    defer { if self.contextPreparationID == preparation { self.contextPreparationTask = nil } }
                    self.targetHighlight.showGuidance(
                        [DoodleMark(shape: .rectangle, rect: rect.insetBy(dx: -6, dy: -4), tone: .violet, label: "Explaining this")],
                        durationNanoseconds: 15_000_000_000)
                    if !self.chatPanel.isVisible { self.overlay.showNearCursor(avoiding: self.targetHighlight.visibleBounds) }
                }
            }
            guard !self.chatPanel.isVisible else { return }
            self.showInSyncWithVoice { [weak self] in
                guard let self else { return }
                self.interaction.transition(to: .answer(display))
                self.interaction.modelLabel = ClaudeAPI.answeredByLabel() ?? self.interaction.modelLabel
                self.interaction.setActions()
                self.overlay.showNearCursor()
            }
        }
        chatStore.onAssistantUpdate = { [weak self] response in
            guard let self else { return }
            if self.shouldSpeakNextAnswer { self.voiceReply.accept(response, final: false) }
            guard !self.chatPanel.isVisible else { return }
            self.showInSyncWithVoice { [weak self] in
                guard let self else { return }
                self.interaction.transition(to: .answer(response))
                self.interaction.setActions(cancel: true)
                self.overlay.refreshVisibleContent()
            }
        }
        chatStore.onNeedsScreen = { [weak self] question in
            guard let self else { return }
            self.understandScreen(question: question, inChat: self.chatPanel.isVisible,
                                  cursor: self.chatPanel.isVisible ? nil : self.pointedLocation)
        }
        chatStore.onFailure = { [weak self] error in
            guard let self else { return }
            self.pendingSelectionMark?.cancel()
            self.pendingSelectionMark = nil
            self.pendingWriteTarget = nil
            self.pendingEdit = nil
            self.shouldSpeakNextAnswer = false
            self.voiceReply.stop()
            guard !self.chatPanel.isVisible else { return }
            self.interaction.transition(to: .failed(error.localizedDescription))
            self.interaction.setActions(retry: true)
            self.overlay.showNearCursor()
        }
        speech.onUpdate = { [weak self] update in
            guard let self, self.speechTurnIsActive else { return }
            self.latency.end("ptt_release_to_first_update")
            self.transcriptVisibleThisTurn = self.transcriptVisibleThisTurn || !update.text.isEmpty
            if !update.text.isEmpty { self.latestPartialTranscript = update.text }
            if self.activeSpeechMode == .dictation {
                // fn⌃ is pure speech-to-text: every word is typed as spoken.
                // Requests like "write a mail" belong to ⌃⌥ instead.
                _ = self.liveDictationSession?.replaceDraft(with: update.text)
            }
            self.interaction.transition(to: .transcript(update.text, isFinal: update.isFinal))
            if !self.circleFocus.isDrawing { self.overlay.refreshVisibleContent() }
        }
        speech.onComplete = { [weak self] transcript, intent in
            Diagnostics.log("stt", ["event": "app_received", "turnActive": self?.speechTurnIsActive ?? false,
                                    "mode": "\(self?.activeSpeechMode as Any)", "chars": transcript.count])
            guard let self, self.speechTurnIsActive || self.selfTestRunning else { return }
            self.speechTurnIsActive = false
            self.voiceMeter.end()
            self.latency.end("ptt_release_to_final")
            self.latency.appendCompletedSample()
            self.latestPartialTranscript = transcript
            if self.activeSpeechMode == .command, self.submitFocusedQuestion(transcript) { return }
            self.interaction.transition(to: .transcript(transcript, isFinal: true))
            self.overlay.showNearCursor()
            if self.selfTestRunning {
                self.selfTestContinuation?.resume()
                self.selfTestContinuation = nil
                return
            }
            // Nothing was said: say so and tuck away, instead of "Thinking…"
            // forever. Not counted as an ask, no empty conversation.
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.liveDictationSession?.cancel()
                self.liveDictationSession = nil
                let wasDictating = self.activeSpeechMode == .dictation
                self.activeSpeechMode = .command
                self.shouldSpeakNextAnswer = false
                self.interaction.transition(to: .transcript(
                    wasDictating ? "Didn't hear anything — hold fn ⌃ and speak." : "Didn't catch that — hold ⌃⌥ and try again.",
                    isFinal: true))
                self.overlay.showNearCursor()
                self.scheduleDismissal()
                return
            }
            if self.activeSpeechMode == .dictation {
                let output = DictationProcessor.process(
                    transcript,
                    mode: self.dictationPreferences.mode,
                    corrections: self.correctionStore.corrections
                )
                if let session = self.liveDictationSession {
                    let result = session.finish(with: output)
                    self.liveDictationSession = nil
                    switch result {
                    case .inserted:
                        break
                    case .failedWithDraft:
                        self.activeSpeechMode = .command
                        self.interaction.transition(to: .failed(
                            "The focused app kept the live draft, but Bibbles could not replace it with the final dictation. Review that draft before editing further. You can copy the final text below."
                        ))
                        self.interaction.offerRecoveryText(output)
                        self.overlay.showNearCursor()
                        return
                    case .failedWithoutDraft:
                        do { try self.textInserter.insert(output) }
                        catch {
                            self.activeSpeechMode = .command
                            self.interaction.transition(to: .failed(error.localizedDescription))
                            self.overlay.showNearCursor()
                            return
                        }
                    }
                } else {
                    do { try self.textInserter.insert(output) }
                    catch {
                        self.activeSpeechMode = .command
                        self.interaction.transition(to: .failed(error.localizedDescription))
                        self.overlay.showNearCursor()
                        return
                    }
                }
                self.recordSuccessfulDictation(output)
                self.activeSpeechMode = .command
                self.interaction.transition(to: .transcript(output, isFinal: true))
                self.scheduleDismissal()
                return
            }
            self.shouldSpeakNextAnswer = self.voiceRepliesEnabled && intent != .dictate
            self.thinkingCuePlayed = false
            Diagnostics.log("voice_turn", ["intent": String("\(intent)".prefix(while: { $0 != "(" })), "voiceOn": self.voiceRepliesEnabled])
            self.dispatch(intent, transcript: transcript)
        }
        speech.onError = { [weak self] error in
            Diagnostics.log("stt", ["event": "app_error", "turnActive": self?.speechTurnIsActive ?? false])
            guard let self, self.speechTurnIsActive || self.selfTestRunning else { return }
            self.speechTurnIsActive = false
            if self.activeSpeechMode == .command, self.submitFocusedQuestion(self.latestPartialTranscript) {
                self.voiceMeter.end()
                return
            }
            self.shouldSpeakNextAnswer = false
            self.voiceMeter.end()
            self.lastFailedSpeechMode = self.activeSpeechMode
            self.interaction.transition(to: .failed(error.localizedDescription))
            self.interaction.setActions(useTranscriptAnyway: !self.latestPartialTranscript.isEmpty)
            self.liveDictationSession?.cancel()
            self.liveDictationSession = nil
            self.activeSpeechMode = .command
            self.overlay.showNearCursor()
            if self.selfTestRunning {
                try? error.localizedDescription.write(
                    toFile: "/tmp/bibbles-selftest-error.txt",
                    atomically: true,
                    encoding: .utf8
                )
                self.selfTestContinuation?.resume()
                self.selfTestContinuation = nil
            }
        }
        composer.onSubmit = { [weak self] text, searchWeb in
            guard let self else { return }
            self.interaction.transition(to: .transcript(text, isFinal: true))
            self.overlay.showNearCursor()
            if searchWeb {
                self.handle(.search(query: text), transcript: text)
            } else {
                self.dispatch(self.intentRouter.route(transcript: text, mode: .command), transcript: text)
            }
        }
    }

    /// The notch bar replaces the menu-bar icon. The icon comes back if the
    /// notch bar is turned off (so Bibbles is always reachable) or if the
    /// user turns it on in Settings → General.
    private func updateMenuBarIcon() {
        let wanted = UserDefaults.standard.bool(forKey: "bibbles.showMenuBarIcon") || !notchHistoryEnabled
        if wanted, statusItem == nil {
            configureMenuBar()
        } else if !wanted, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = BibblesBrandIcon.menuBarImage()
        let menu = NSMenu(title: "Bibbles")
        menu.delegate = self
        item.menu = menu
        statusItem = item
        populateMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        // Items are enabled or disabled explicitly below.
        menu.autoenablesItems = false
        let permissions = PermissionService.snapshot()
        let accountReady = AccountSession.shared.email != nil
        let vocabularyCount = SpeechVocabularyStore().terms.count
        let minutesSaved = usageMetrics.weeklyMinutesSaved()
        let microphoneReady = permissions.microphone == .authorized
        let ready = accountReady && permissions.accessibility && microphoneReady
        #if BIBBLES_DEVELOPER
        // Developer builds: hold Option while opening the menu to show developer tools.
        let showDeveloperTools = NSEvent.modifierFlags.contains(.option)
            || ProcessInfo.processInfo.environment["BIBBLES_DEVELOPER"] == "1"
        #else
        let showDeveloperTools = false
        #endif

        let header = NSMenuItem(title: ready ? "Bibbles is ready" : "Bibbles setup needed", action: nil, keyEquivalent: "")
        header.image = NSImage(systemSymbolName: ready ? "checkmark.circle.fill" : "exclamationmark.circle", accessibilityDescription: nil)
        header.isEnabled = false
        menu.addItem(header)
        // Only list what still needs attention, so a ready app has a short menu.
        let checks: [(String, Bool)] = [
            ("Signed in", accountReady),
            ("Accessibility", permissions.accessibility),
            ("Microphone", microphoneReady),
            ("Screen Recording", permissions.screenRecording)
        ]
        for (title, isReady) in checks where !isReady || showDeveloperTools {
            menu.addItem(statusItem(title: title, ready: isReady))
        }
        if !permissions.accessibility || !microphoneReady || !permissions.screenRecording {
            addItem(to: menu, "Fix Permissions…", #selector(showPermissionStatus))
        }
        menu.addItem(.separator())

        addItem(to: menu, "Type to Bibbles…", #selector(openComposer))
        addItem(to: menu, "Open Chat", #selector(openChat), detail: "⌃⌘A")
        addItem(to: menu, "Quick Web Search…", #selector(openQuickWebSearch))
        addItem(to: menu, "Show Last Answer", #selector(showLastAnswer)).isEnabled = interaction.lastAnswer != nil
        addItem(to: menu, "Copy Last Answer", #selector(copyLastAnswer)).isEnabled = interaction.lastAnswer != nil
        #if BIBBLES_DEVELOPER
        if AgentUndoRegistry.shared.latest != nil {
            addItem(to: menu, "Undo Last Agent Task", #selector(undoLastAgentTask))
        }
        #endif
        if targetHighlight.hasDrawing || targetHighlight.canUndoDrawing {
            addItem(to: menu, "Undo Drawing", #selector(undoScreenDrawing)).isEnabled = targetHighlight.canUndoDrawing
            addItem(to: menu, "Clear Drawings", #selector(clearScreenDrawings), detail: "Esc")
                .isEnabled = targetHighlight.hasDrawing
        }
        menu.addItem(.separator())

        addItem(to: menu, "Settings…", #selector(openSettings), key: ",")
        // Settings
        let settings = NSMenu(title: "Settings")
        let speak = addItem(to: settings, "Speak Answers Aloud", #selector(toggleVoiceReplies))
        speak.state = voiceRepliesEnabled ? .on : .off
        let notch = addItem(to: settings, "Show Task History at Notch", #selector(toggleNotchHistory))
        notch.state = notchHistoryEnabled ? .on : .off
        let modelMenu = NSMenu(title: "AI Model")
        for preference in ClaudeAPI.ModelPreference.allCases {
            let item = addItem(to: modelMenu, preference.title, #selector(selectModelPreference(_:)))
            item.representedObject = preference.rawValue
            item.state = ClaudeAPI.preference == preference ? .on : .off
            // Fixed on Auto: the other choices are shown greyed out.
            if preference != .auto { item.action = nil; item.isEnabled = false }
        }
        settings.addItem(submenuItem("AI Model: \(ClaudeAPI.preference == .auto ? "Auto" : ClaudeAPI.preference.title)", modelMenu))
        let modeMenu = NSMenu(title: "Dictation Mode")
        for mode in DictationOutputMode.allCases {
            let item = addItem(to: modeMenu, mode.title, #selector(selectDictationMode(_:)))
            item.representedObject = mode.rawValue
            item.state = dictationPreferences.mode == mode ? .on : .off
        }
        settings.addItem(submenuItem("Dictation Mode: \(dictationPreferences.mode.title)", modeMenu))
        settings.addItem(.separator())
        addItem(to: settings, "Technical Vocabulary…  (\(vocabularyCount)/100)", #selector(configureVocabulary))
        addItem(to: settings, "Teach a Correction…", #selector(teachCorrection))
        addItem(to: settings, "Report a Dictation Correction…", #selector(reportDictationCorrection))
        settings.addItem(.separator())
        addItem(to: settings, "Clear Chat History…", #selector(clearChatHistory))
        settings.addItem(.separator())
        let login = addItem(to: settings, "Open at Login", #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(submenuItem("More Settings", settings))

        // Help
        let help = NSMenu(title: "Help")
        addItem(to: help, "Getting Started…", #selector(showGettingStarted))
        addItem(to: help, "Setup Tutorial…", #selector(showSetupTutorial))
        addItem(to: help, "About Bibbles", #selector(showAbout))
        addItem(to: help, "Permissions…", #selector(showPermissionStatus))
        menu.addItem(submenuItem("Help", help))

        #if BIBBLES_DEVELOPER
        if showDeveloperTools {
            let developer = NSMenu(title: "Developer")
            addItem(to: developer, "Test local capture + OCR", #selector(testScreenCapture))
            addItem(to: developer, "Test screen grounding…", #selector(testVisionGrounding))
            developer.addItem(.separator())
            let recording = addItem(to: developer, ToolGateStrings.menuRecordLog, #selector(toggleToolGateLog))
            recording.state = ToolGateLog.shared.isRecording ? .on : .off
            addItem(to: developer, "\(ToolGateStrings.menuCopyLog) (\(ToolGateLog.shared.entries.count))", #selector(copyToolGateLog))
            addItem(to: developer, ToolGateStrings.menuClearLog, #selector(clearToolGateLog))
            developer.addItem(.separator())
            let keywords = addItem(to: developer, "Keyword improvements: \(HybridRouter.keywordImprovementsEnabled ? "On" : "Off")",
                                   #selector(toggleKeywordImprovements))
            keywords.state = HybridRouter.keywordImprovementsEnabled ? .on : .off
            addItem(to: developer, "API Keys & Local Mode…", #selector(openDeveloperSettings))
            addItem(to: developer, DeveloperControls.shared.testRunning ? "Run Router Test Set (running…)" : "Run Router Test Set (\(RouterTestSet.cases.count))",
                    #selector(runRouterTestSet))
            menu.addItem(submenuItem("Developer", developer))
        }
        #endif

        menu.addItem(.separator())
        let saved = NSMenuItem(
            title: String(format: "This week · about %.0f min saved", max(0, minutesSaved.rounded())),
            action: nil,
            keyEquivalent: ""
        )
        saved.isEnabled = false
        if minutesSaved >= 1 { menu.addItem(saved) }
        addItem(to: menu, "Quit Bibbles", #selector(quit), key: "q")
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector,
                         detail: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: detail.map { "\(title)  (\($0))" } ?? title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
            interaction.transition(to: .transcript(LaunchAtLogin.isEnabled
                ? "Bibbles will open when you log in" : "Bibbles won't open at login", isFinal: true))
        } catch {
            interaction.transition(to: .failed("Couldn't change Open at Login: \(error.localizedDescription). You can add Bibbles in System Settings → General → Login Items."))
        }
        overlay.showNearCursor()
        scheduleDismissal()
    }

    @objc private func clearChatHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all chat history?"
        alert.informativeText = "This deletes every saved Bibbles conversation on this Mac. It can't be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        chatStore.deleteAllConversations()
        interaction.transition(to: .transcript("Chat history cleared", isFinal: true))
        overlay.showNearCursor()
        scheduleDismissal()
    }

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        let credits = NSAttributedString(
            string: "\(BibblesIdentity.attribution)\nAsk, dictate, and get guidance across your Mac.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Bibbles",
            .applicationVersion: version,
            .version: build,
            .credits: credits
        ])
    }

    private func statusItem(title: String, ready: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "\(ready ? "✓" : "○")  \(title)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The fast model first. Simple screen questions hand over to the deep
    /// model only when the fast answer is broken; charts and complex analysis
    /// also below 75% confidence. Charts go straight to deep. "Always fast" /
    /// "Always advanced" use one model only. The same for every plan.
    private func makeGroundingCoordinator(for kind: ScreenQuestionKind = .general, question: String? = nil,
                                          deep: Bool = false,
                                          onReport: ((ScreenHandOverReport) -> Void)? = nil) -> GroundingCoordinator {
        let key = ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey)
        let environment = ProcessInfo.processInfo.environment
        let primaryModel = environment["BIBBLES_VISION_PRIMARY_MODEL"] != nil
            ? configuration.visionPrimaryModel
            : (kind.isChart || deep ? ClaudeAPI.chartModel : ClaudeAPI.model)
        let fallbackModel: String? = ClaudeAPI.preference == .auto && primaryModel != ClaudeAPI.smartModel
            ? (environment["BIBBLES_VISION_FALLBACK_MODEL"] != nil ? configuration.visionFallbackModel : ClaudeAPI.smartModel)
            : nil
        return GroundingCoordinator(
            primary: MessagesVisionProvider(apiKey: key, baseURL: configuration.visionBaseURL, model: primaryModel),
            fallback: fallbackModel.map { MessagesVisionProvider(apiKey: key, baseURL: configuration.visionBaseURL, model: $0) },
            policy: question.map { ScreenHandOverPolicy.forQuestion($0, kind: kind) } ?? .confidence,
            onReport: onReport
        )
    }

    private func handle(_ action: HotkeyAction) {
        dismissTask?.cancel()
        Diagnostics.log("hotkey", ["action": "\(action)"])
        switch action {
        case .pushToTalkBegan, .dictationBegan, .typedInputRequested, .openChatRequested:
            if firstRunTutorial.isVisible { firstRunTutorial.hide() }
            focusCaptureTask?.cancel()
            focusCaptureTask = nil
            focusPoint = nil
            if action != .pushToTalkBegan { circleFocus.cancel() }
        default: break
        }
        switch action {
        case .pushToTalkBegan:
            focusCaptureTask?.cancel()
            focusCaptureTask = nil
            focusPoint = nil
            focusFinishedSpeech = false
            speechTurnIsActive = true
            voiceReply.stop()
            shouldSpeakNextAnswer = false
            voiceMeter.begin()
            interaction.setActions()
            latestPartialTranscript = ""
            pointedLocation = nil
            latency.clear()
            transcriptVisibleThisTurn = false
            latency.begin("shortcut_to_overlay")
            interaction.transition(to: .listening)
            overlay.showNearCursor()
            if notchHistoryEnabled { notchPill.interactionDidBegin() }
            activeSpeechMode = .command
            #if BIBBLES_DEVELOPER
            RouterWarmUp.ifNeeded()
            #endif
            latency.end("shortcut_to_overlay")
            speechStartTask = Task { await speech.begin(mode: .command) }
        case .pushToTalkEnded:
            guard !focusFinishedSpeech else { return }
            voiceMeter.end()
            pointedLocation = NSEvent.mouseLocation
            beginReleaseLatency()
            let startTask = speechStartTask
            Task {
                _ = await startTask?.value
                await speech.finish()
            }
        case .dictationBegan:
            voiceReply.stop()
            shouldSpeakNextAnswer = false
            guard PermissionService.requestAccessibility() else {
                interaction.transition(to: .failed(
                    FocusedTextInsertionError.accessibilityPermissionRequired.localizedDescription
                ))
                interaction.setActions()
                overlay.showNearCursor()
                if notchHistoryEnabled { notchPill.interactionDidBegin() }
                return
            }
            speechTurnIsActive = true
            interaction.setActions()
            voiceMeter.begin()
            latestPartialTranscript = ""
            dictationBeganAt = Date()
            dictationSpokenSeconds = nil
            latency.clear()
            transcriptVisibleThisTurn = false
            interaction.transition(to: .dictating)
            overlay.showNearCursor()
            if notchHistoryEnabled { notchPill.interactionDidBegin() }
            activeSpeechMode = .dictation
            liveDictationSession = textInserter.beginLiveSession()
            speechStartTask = Task { await speech.begin(mode: .dictation) }
        case .dictationEnded:
            guard activeSpeechMode == .dictation else { return }
            voiceMeter.end()
            if let dictationBeganAt {
                dictationSpokenSeconds = Date().timeIntervalSince(dictationBeganAt)
            }
            beginReleaseLatency()
            let startTask = speechStartTask
            Task {
                _ = await startTask?.value
                await speech.finish()
            }
        case .typedInputRequested:
            #if BIBBLES_DEVELOPER
            RouterWarmUp.ifNeeded()
            #endif
            voiceReply.stop()
            shouldSpeakNextAnswer = false
            openComposer()
        case .openChatRequested:
            reopenChatWhenNearNotch = false
            chatPanel.show()
        case .dismissPanels:
            dismissPanels()
        }
    }

    // MARK: Hybrid router (developer toggle "AI Router (Haiku)")

    /// Today's dispatch, unchanged, unless the developer AI Router toggle is
    /// on: then keywords decide first, and Claude Haiku labels only the
    /// requests they can't decide. The user's words are never changed.
    private func dispatch(_ intent: BibblesIntent, transcript: String) {
        #if BIBBLES_DEVELOPER
        if intent != .dictate, handleAgentVoiceCommand(transcript) { return }
        #endif
        if intent != .dictate { stopWalkthrough() }
        var intent = intent
        var hereWrite = false
        // Always on: "…write a mail to my HR here" is not a screen question.
        // "here" alone doesn't start screen help when a text box is focused
        // or the request clearly asks to write.
        if case .screen = intent {
            let decided = intentRouter.decide(transcript: transcript, mode: .command)
            if decided.intent == intent,
               let corrected = IntentRouter.hereScreenCorrection(
                for: transcript, decided: decided,
                textFieldFocused: RouterFlagsProbe.textFieldFocused(app: lastExternalApp)) {
                if !HybridRouter.pathActive, IntentRouter.clearlyAsksToWrite(transcript) {
                    pendingVisualQuestion = nil
                    beginTaskConversationIfNeeded(for: transcript)
                    usageMeter.recordAsk()
                    performWriteAction(transcript, screenContent: false, allowForm: true)
                    ToolGateLog.shared.recordRouting(
                        RoutingDecision(source: .keyword, override: .write, keywordStrength: .weak, reason: "here fix"),
                        text: transcript, finalRoute: "write (here fix)", tier: "light")
                    return
                }
                hereWrite = IntentRouter.clearlyAsksToWrite(transcript)
                intent = corrected
            }
        }
        guard HybridRouter.pathActive, intent != .dictate,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            handle(intent, transcript: transcript)
            return
        }
        let flags = RouterFlagsProbe.flags(app: lastExternalApp)
        interaction.transition(to: .working("Thinking…"))
        overlay.showNearCursor()
        let preparation = beginContextPreparation()
        contextPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let decision = await HybridRouter.decide(text: transcript, flags: flags, intentRouter: self.intentRouter,
                                                     useRouter: HybridRouter.isEnabled,
                                                     improvements: HybridRouter.keywordImprovementsEnabled)
            // Escape or a new request while deciding: do nothing.
            guard self.isCurrentContextPreparation(preparation) else { return }
            self.contextPreparationTask = nil
            let ran = self.runRouted(decision, intent: intent, transcript: transcript, hereWrite: hereWrite)
            ToolGateLog.shared.recordRouting(decision, text: transcript, finalRoute: ran.route, tier: ran.tier)
        }
    }

    /// Runs the routed task with the user's original text. Returns what ran
    /// (for the developer log).
    private func runRouted(_ decision: RoutingDecision, intent: BibblesIntent,
                           transcript: String, hereWrite: Bool = false) -> (route: String, tier: String) {
        /// Today's behaviour, including the always-on "here" fix.
        func fallBack() -> (route: String, tier: String) {
            if hereWrite {
                pendingVisualQuestion = nil
                beginTaskConversationIfNeeded(for: transcript)
                usageMeter.recordAsk()
                performWriteAction(transcript, screenContent: false, allowForm: true)
                return ("today:write (here fix)", "light")
            }
            handle(intent, transcript: transcript)
            return ("today:" + todayLabel(intent, transcript: transcript), "today")
        }
        guard let route = decision.override, route != .unclear else { return fallBack() }
        pendingVisualQuestion = nil
        let deepAllowed = ToolGate.mode(for: .deep, preference: ClaudeAPI.preference,
                                        deepTasksLeft: ToolGate.deepTasksLeft) == .deep
        let lightTier = ClaudeAPI.preference == .sonnet && deepAllowed ? "deep" : "light"
        switch route {
        case .simple, .deep:
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
            interaction.transition(to: .working("Thinking…"))
            overlay.showNearCursor()
            // "deep" still needs deep tasks left; otherwise the light model answers.
            chatStore.send(transcript, routeOverride: route == .deep ? .deep : .simple)
            return (route.rawValue, route == .deep ? (deepAllowed ? "deep" : "light") : lightTier)
        case .write:
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
            performWriteAction(transcript, screenContent: true, allowForm: false)
            return ("write", lightTier)
        case .formFill:
            guard let target = lastExternalApp, !target.isTerminated,
                  let key = ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey), !key.isEmpty else { return fallBack() }
            let fields = formScanner.fields(in: target)
            guard fields.count >= 2 else { return fallBack() }
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
            shouldSpeakNextAnswer = false
            voiceReply.stop()
            fillForm(transcript, in: target, fields: fields, apiKey: key)
            return ("form_fill", "light")
        case .edit:
            beginTaskConversationIfNeeded(for: transcript)
            guard startEdit(transcript) else { return fallBack() }
            usageMeter.recordAsk()
            return ("edit", lightTier)
        case .fixText, .fixCode:
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
            shouldSpeakNextAnswer = false
            voiceReply.stop()
            fixText(transcript)
            return (route.rawValue, "fix")
        case .translate:
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
            // Without a shared selection this falls back to the screen path.
            askAboutSelection(transcript, forceRead: true)
            return ("translate", lightTier)
        case .screen:
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
            understandScreen(question: transcript, cursor: pointedLocation)
            return ("screen", "vision")
        case .search:
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
            interaction.transition(to: .working("Searching the web…"))
            overlay.showNearCursor()
            chatStore.send(transcript, useWebSearch: true)
            return ("search", "search")
        case .command, .fileAction:
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
            performFileAction(transcript)
            return (route.rawValue, "agent")
        #if BIBBLES_DEVELOPER
        case .agentFiles:
            startFilesAgent(transcript, layer: "router")
            return ("agent_files", "agent")
        case .agentScreen:
            startScreenAgent(transcript, layer: "router")
            return ("agent_screen", "agent")
        #endif
        case .unclear:
            return fallBack()
        }
    }

    private func todayLabel(_ intent: BibblesIntent, transcript: String) -> String {
        HybridRouter.route(for: intent, text: transcript, flags: RouterFlags(), intentRouter: intentRouter).rawValue
    }

    #if BIBBLES_DEVELOPER
    @objc private func toggleKeywordImprovements() {
        DeveloperControls.shared.setKeywordImprovements(!HybridRouter.keywordImprovementsEnabled)
        var note = "Keyword improvements: \(HybridRouter.keywordImprovementsEnabled ? "On" : "Off")"
        if HybridRouter.keywordImprovementsEnabled, !ToolGate.isEnabled { note += " — turn the Tool Gate on too" }
        showDeveloperNote(note)
    }

    @objc private func toggleAIRouter() {
        DeveloperControls.shared.setAIRouter(!HybridRouter.isEnabled)
        var note = "AI Router (Haiku): \(HybridRouter.isEnabled ? "On" : "Off")"
        if HybridRouter.isEnabled {
            if !ToolGate.isEnabled { note += " — turn the Tool Gate on too" }
            else if !DeveloperKeychain.has(.anthropic) { note += " — add an Anthropic key in Settings → Developer (keywords only until then)" }
            RouterWarmUp.ifNeeded()
        }
        showDeveloperNote(note)
    }

    /// Keys are pasted only on Settings → Developer (Paste & Save), never typed into an alert.
    @objc private func openDeveloperSettings() {
        settingsWindow.show(section: .developer)
    }

    @objc private func runRouterTestSet() {
        DeveloperControls.shared.runTestSet { [weak self] note in self?.showDeveloperNote(note) }
    }
    #endif

    private func handle(_ intent: BibblesIntent, transcript: String) {
        pendingVisualQuestion = nil
        if intent != .dictate {
            beginTaskConversationIfNeeded(for: transcript)
            usageMeter.recordAsk()
        }
        // "Change it", "I don't like this story", "make the mail shorter":
        // rewrite what Bibbles wrote (or the highlight) and replace it.
        if intent != .dictate, !intentRouter.isCommandRequest(transcript),
           EditRequest.isEdit(transcript), startEdit(transcript) {
            return
        }
        switch intent {
        case .chat, .screen:
            let localStarted = Date()
            if let answer = LocalQuickAnswer.answer(for: transcript) {
                ToolGateLog.shared.recordLocal(route: .localAnswer, text: transcript, started: localStarted)
                chatStore.recordExchange(userText: transcript, assistantText: answer)
                speakLocalAnswerIfNeeded(answer)
                showInSyncWithVoice { [weak self] in
                    guard let self else { return }
                    self.interaction.transition(to: .answer(answer))
                    self.interaction.setActions()
                    self.overlay.showNearCursor()
                }
                return
            }
        case .dictate, .search:
            break
        }
        switch intent {
        case .dictate:
            shouldSpeakNextAnswer = false
            do {
                try textInserter.insert(transcript)
                interaction.transition(to: .transcript(transcript, isFinal: true))
                scheduleDismissal()
            } catch {
                interaction.transition(to: .failed(error.localizedDescription))
                scheduleDismissal(afterNanoseconds: 4_000_000_000)
            }
        case .screen:
            understandScreen(question: transcript, cursor: pointedLocation)
        case let .search(query):
            interaction.transition(to: .working("Searching the web…"))
            overlay.showNearCursor()
            let preparation = beginContextPreparation()
            contextPreparationTask = Task {
                let context = await focusedContext(for: transcript)
                guard isCurrentContextPreparation(preparation) else { return }
                chatStore.send(query, useWebSearch: true, focusedContext: context)
            }
        case .chat:
            if intentRouter.isCommandRequest(transcript) {
                performFileAction(transcript)
                return
            }
            if intentRouter.isFixRequest(transcript) {
                shouldSpeakNextAnswer = false
                voiceReply.stop()
                fixText(transcript)
                return
            }
            if intentRouter.isActionRequest(transcript) {
                performWriteAction(transcript, screenContent: intentRouter.isWriteRequest(transcript), allowForm: true)
                return
            }
            if MessagesVisualExplanationProvider.isRequested(transcript), !intentRouter.shouldUseFocusedText(for: transcript) {
                requestVisualExplanation(transcript)
                return
            }
            guard intentRouter.shouldUseFocusedText(for: transcript) else {
                interaction.transition(to: .working("Thinking…"))
                overlay.showNearCursor()
                chatStore.send(transcript)
                return
            }
            askAboutSelection(transcript)
        }
    }

    /// Writes (or fills a form) in the user's app. Shared by today's keyword
    /// dispatch and the hybrid router; behaviour is unchanged.
    private func performWriteAction(_ transcript: String, screenContent: Bool, allowForm: Bool) {
        shouldSpeakNextAnswer = false
        voiceReply.stop()
        // "Write the answer to this question (on screen)": look at the
        // screen first, then type only the answer into the user's app.
        if screenContent, IntentRouter.refersToScreenContent(transcript),
           let target = lastExternalApp, !target.isTerminated,
           let key = ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey), !key.isEmpty {
            writeFromScreen(transcript, into: target, apiKey: key)
            return
        }
        // An email asked for in a compose window (even when routed as plain
        // writing): fill To, Subject and the message body separately.
        let emailRequest = MailCompose.isEmailRequest(transcript)
        if allowForm || emailRequest, let target = lastExternalApp, !target.isTerminated,
           let key = ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey), !key.isEmpty {
            let fields = formScanner.fields(in: target)
            if fields.count >= 2, allowForm || MailCompose.isComposeWindow(labels: fields.map(\.label)) {
                fillForm(transcript, in: target, fields: fields, apiKey: key)
                return
            }
        }
        pendingWriteTarget = lastExternalApp
        pendingWriteRequest = transcript
        pendingEdit = nil
        let appName = lastExternalApp?.localizedName ?? "your app"
        interaction.transition(to: .working("Writing it for \(appName)…"))
        interaction.setActions(cancel: true)
        overlay.showNearCursor()
        chatStore.send(transcript, writeMode: true)
    }

    /// Answers about the user's selected text; when the app doesn't share
    /// its selection, looks at the screen instead. `forceRead` reads the
    /// selection even without words like "this text" (hybrid router).
    private func askAboutSelection(_ transcript: String, forceRead: Bool = false) {
        do {
            interaction.transition(to: .working("Reading the selected text…"))
            overlay.showNearCursor()
            let preparation = beginContextPreparation()
            contextPreparationTask = Task {
                let context = forceRead ? await focusedContextReader.snapshot() : await focusedContext(for: transcript)
                // Cancelled while reading the selection: send nothing.
                guard isCurrentContextPreparation(preparation) else { return }
                guard context?.hasSelectedText == true else {
                    // The app didn't share its selection (common in browsers
                    // and PDFs): look at the screen instead, where the
                    // highlight is visible, rather than failing.
                    understandScreen(question: transcript, cursor: pointedLocation)
                    return
                }
                interaction.transition(to: .working("Thinking…"))
                // Find the highlighted text on screen while Claude answers.
                if let context {
                    pendingSelectionMark?.cancel()
                    let bounds = context.selectionBounds
                    let selected = context.selectedText ?? ""
                    let cursor = pointedLocation ?? NSEvent.mouseLocation
                    pendingSelectionMark = Task { @MainActor [weak self] () -> CGRect? in
                        if let bounds { return bounds }
                        return await self?.locateOnScreen(selected, near: cursor)
                    }
                }
                chatStore.send(transcript, focusedContext: context)
            }
        }
    }

    private func submitFromChat(_ text: String, documents: [ChatDocument], searchWeb: Bool = false) -> Bool {
        pendingVisualQuestion = nil
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !documents.isEmpty else { return false }
        stopWalkthrough()
        usageMeter.recordAsk()
        if searchWeb {
            chatStore.send(question, documents: documents, useWebSearch: true)
            return true
        }
        if documents.isEmpty, LocalQuickAnswer.answer(for: question) != nil {
            chatStore.send(question)
            return true
        }
        switch intentRouter.route(transcript: question, mode: .command) {
        case .screen:
            guard documents.isEmpty else {
                chatStore.statusMessage = "Remove attachments to ask about the screen."
                return false
            }
            understandScreen(question: question, inChat: true)
        case let .search(query):
            chatStore.send(query, documents: documents, useWebSearch: true)
        case .chat, .dictate:
            if documents.isEmpty, MessagesVisualExplanationProvider.isRequested(question), !intentRouter.shouldUseFocusedText(for: question) {
                requestVisualExplanation(question)
                return true
            }
            if documents.isEmpty, intentRouter.shouldUseFocusedText(for: question) {
                chatStore.statusMessage = "Select text in the source app and use Control + Option to ask about it."
                return false
            }
            chatStore.send(question, documents: documents)
        }
        return true
    }

    private func captureFocus(_ selection: CircleFocusSelection) {
        focusCaptureTask?.cancel()
        focusPoint = CGPoint(x: selection.rect.midX, y: selection.rect.midY)
        focusCaptureTask = Task { try await screenCapture.captureFocusRegion(selection) }
        focusFinishedSpeech = true
        voiceMeter.end()
        if speechTurnIsActive {
            // Mouse-up ends this voice turn; releasing the chord must not finish it twice.
            beginReleaseLatency()
            let start = speechStartTask
            Task { _ = await start?.value; await speech.finish() }
        } else {
            _ = submitFocusedQuestion(latestPartialTranscript)
        }
    }

    @discardableResult
    private func submitFocusedQuestion(_ transcript: String) -> Bool {
        guard let capture = focusCaptureTask else { return false }
        focusCaptureTask = nil
        let point = focusPoint
        focusPoint = nil
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = spoken.isEmpty ? "Explain the circled area." : spoken
        beginTaskConversationIfNeeded(for: question)
        usageMeter.recordAsk()
        shouldSpeakNextAnswer = voiceRepliesEnabled
        thinkingCuePlayed = false
        understandScreen(question: question, captureTask: capture, cursor: point)
        return true
    }

    private func understandScreen(
        question: String,
        captureTask: Task<ScreenCaptureResult, Error>? = nil,
        inChat: Bool = false,
        cursor: CGPoint? = nil
    ) {
        stopWalkthrough()
        let kind = ScreenQuestionKind.classify(question)
        // Charts and step-by-step guides are deep analysis.
        if kind == .chartAnalysis || kind == .chartCandle || kind == .howTo { usageMeter.recordDeepTask() }
        let capturePoint = cursor ?? NSEvent.mouseLocation
        if let drawing = SimpleDrawingCommand.parse(question) {
            screenQuestionTask?.cancel()
            screenQuestionTask = nil
            if let activeScreenChatID { chatStore.cancelScreenQuestion(in: activeScreenChatID) }
            activeScreenChatID = nil
            chatStore.statusMessage = nil
            let answer: String
            if drawing == .clear {
                targetHighlight.hide()
                answer = "Drawings cleared."
            } else if drawing == .undo {
                answer = targetHighlight.undoDrawing() ? "Last drawing removed." : "There are no drawings to undo."
            } else if let shape = drawing.shape,
                      targetHighlight.draw(shape, at: capturePoint, tone: DoodleTone.requested(in: question), request: question) {
                answer = "Drew a \(shape.rawValue) by your pointer. Say ‘undo drawing’ to remove it, or press Escape to clear the canvas."
            } else {
                answer = "I couldn't find a display at your pointer. Move the pointer onto the screen and try again."
            }
            chatStore.recordExchange(userText: question, assistantText: answer)
            speakLocalAnswerIfNeeded(answer)
            if !inChat {
                interaction.transition(to: .answer(answer))
                interaction.setActions()
                overlay.showNearCursor(avoiding: targetHighlight.visibleBounds)
            }
            return
        }
        let chatConversationID = inChat ? chatStore.beginScreenQuestion(question) : nil
        if inChat, chatConversationID == nil { return }
        guard AccountSession.shared.email != nil || Backends.isLocal else {
            shouldSpeakNextAnswer = false
            if let chatConversationID {
                chatStore.failScreenQuestion(WorkerError.signInRequired, in: chatConversationID)
            } else {
                interaction.transition(to: .failed(WorkerError.signInRequired.localizedDescription))
                overlay.showNearCursor()
            }
            return
        }
        guard captureTask != nil || PermissionService.requestScreenRecording() else {
            shouldSpeakNextAnswer = false
            if let chatConversationID {
                chatStore.failScreenQuestion(ScreenCaptureServiceError.permissionRequired, in: chatConversationID)
            } else {
                interaction.transition(to: .failed(ScreenCaptureServiceError.permissionRequired.localizedDescription))
                overlay.showNearCursor()
            }
            return
        }
        playThinkingCueIfSpoken()
        screenQuestionTask?.cancel()
        if let activeScreenChatID { chatStore.cancelScreenQuestion(in: activeScreenChatID) }
        activeScreenChatID = chatConversationID
        let generation = UUID()
        screenQuestionGeneration = generation
        // A spoken question keeps its "answer out loud" until its own answer
        // arrives, even if something else touched the shared flag meanwhile.
        let speakThisAnswer = shouldSpeakNextAnswer
        Diagnostics.log("screen_question", ["kind": "\(kind)", "speak": speakThisAnswer, "inChat": inChat])
        if !inChat {
            interaction.transition(to: .working(
                kind == .chartCandle ? "Finding that candle…" :
                    (kind == .findControl ? "Finding the control…" : "Looking at this area…")
            ))
            overlay.showNearCursor()
            targetHighlight.showScanning(at: capturePoint)
        }
        screenQuestionTask = Task {
            defer {
                if screenQuestionGeneration == generation {
                    screenQuestionTask = nil
                    activeScreenChatID = nil
                }
            }
            do {
                screenLatency.clear()
                screenLatency.begin("capture")
                let capture: ScreenCaptureResult
                if let captureTask { capture = try await captureTask.value }
                else if inChat || intentRouter.shouldUseScreenOverview(for: question) {
                    capture = try await screenCapture.captureDisplayOverview(cursor: capturePoint)
                } else {
                    capture = try await screenCapture.captureCursorCrop(cursor: capturePoint)
                }
                try Task.checkCancellation()
                screenLatency.end("capture")
                screenLatency.begin("local_ocr")
                // Charts: read the full-resolution capture accurately so the
                // tiny price-scale numbers can be mapped to screen positions.
                let observations: [OCRObservation]
                // Charts and "where is X": read the full-resolution capture
                // accurately, so small labels (desktop icon names, price
                // scales) are found and marks land on the exact text.
                if kind == .chartAnalysis || kind == .findControl || kind == .howTo || kind == .general {
                    observations = try await ocr.recognizeText(in: capture.fullResolution ?? capture.image, accurate: true)
                } else {
                    observations = kind.needsOCR ? try await ocr.recognizeText(in: capture.image) : []
                }
                screenLatency.end("local_ocr")
                let request = VisionGroundingRequest(
                    question: question,
                    image: capture.image,
                    ocr: observations,
                    descriptor: capture.descriptor,
                    pointerInImage: inChat ? nil : CoordinateMapper.normalizedPoint(
                        for: capturePoint,
                        descriptor: capture.descriptor
                    ),
                    kind: kind
                )
                screenLatency.begin("vision_grounding")
                let visionStarted = Date()
                var screenReport: ScreenHandOverReport?
                // Diagrams and formulas go to the deep model; words, text and
                // interface questions stay on the fast one. Decided on this Mac.
                let diagramDeep = kind == .general
                    && ClaudeAPI.preference != .haiku
                    && (ToolGate.deepTasksLeft ?? 1) > 0
                    && ScreenComplexity.needsDeep(question: question, ocr: observations)
                if diagramDeep { usageMeter.recordDeepTask() }
                Diagnostics.log("screen_tier", ["kind": "\(kind)", "deep": diagramDeep])
                let answer = try await makeGroundingCoordinator(for: kind, question: question, deep: diagramDeep,
                                                                onReport: { screenReport = $0 }).ground(request)
                if ToolGateLog.shared.isRecording, let screenReport {
                    // Developer log: route, tier and why it was handed over (no user text).
                    let elapsed = Int(Date().timeIntervalSince(visionStarted) * 1000)
                    ToolGateLog.shared.record(ToolGateLog.Entry(
                        date: Date(), gateOn: ToolGate.isEnabled, language: ToolGate.detectLanguage(question).code,
                        route: "screen", tier: screenReport.tier, firstWordMilliseconds: elapsed,
                        totalMilliseconds: elapsed, handOver: screenReport.handOver ?? "—"))
                }
                try Task.checkCancellation()
                guard screenQuestionGeneration == generation else { return }
                ProductAnalytics.shared.track(.screenHelpCompleted)
                screenLatency.end("vision_grounding")
                screenLatency.appendCompletedSample(to: URL(fileURLWithPath: "/tmp/bibbles-screen-guidance-latency.jsonl"))
                if let lesson = answer.visualExplanation, answer.walkthrough.count < 2 {
                    targetHighlight.hide()
                    overlay.hide()
                    shouldSpeakNextAnswer = false
                    voiceReply.stop()
                    if let chatConversationID {
                        chatStore.completeScreenQuestion(lesson.transcript, in: chatConversationID)
                    } else {
                        chatStore.recordExchange(userText: question, assistantText: lesson.transcript)
                    }
                    interaction.rememberAnswer(lesson.transcript)
                    visualExplanation.show(lesson, provenance: "AI visual explanation")
                    return
                }
                var doodles: [DoodleMark] = []
                let displayUnchanged = NSScreen.screens.contains { screen in
                    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                    return number?.uint32Value == capture.descriptor.displayID
                        && screen.frame == capture.descriptor.displayFrameInQuartzPoints
                }
                if displayUnchanged, answer.confidence >= 0.6 {
                    let tones: [DoodleTone] = [.violet, .teal, .amber, .coral]
                    doodles = answer.annotations.enumerated().compactMap { index, annotation in
                        guard annotation.isRenderable,
                              let rect = try? CoordinateMapper.globalQuartzRect(for: annotation.target, descriptor: capture.descriptor, maximumAge: Self.markMaximumAge) else { return nil }
                        return DoodleMark(shape: annotation.shape, rect: rect,
                                          from: index == 0 && !inChat ? capturePoint : nil,
                                          tone: tones[index % tones.count], label: annotation.label, step: annotation.step, dotted: kind == .chartCandle)
                    }
                    if doodles.isEmpty, let target = answer.target,
                       target.width <= 0.4, target.height <= 0.4,
                       let rect = try? CoordinateMapper.globalQuartzRect(for: target, descriptor: capture.descriptor, maximumAge: Self.markMaximumAge) {
                        let normalized = question.lowercased()
                        let shape: DoodleShape = normalized.contains("circle") ? .circle :
                            (normalized.contains("underline") ? .underline : .rectangle)
                        doodles = [DoodleMark(shape: shape, rect: rect, from: inChat ? nil : capturePoint, dotted: kind == .chartCandle)]
                    }
                }
                // No verified target means no mark; nearby text alone is not
                // evidence that it is the object the user asked about.
                var drawingNote: String?
                if kind == .chartAnalysis {
                    if !displayUnchanged {
                        drawingNote = "Lines not drawn: the display changed while Bibbles was thinking. Ask again to draw them."
                    } else if answer.priceLevels.isEmpty {
                        drawingNote = "Lines not drawn: Bibbles couldn't place these levels on the chart. Make sure the price scale on the right is visible, then ask again."
                    }
                }
                if displayUnchanged, !answer.priceLevels.isEmpty {
                    // Support/resistance: full-width horizontal lines placed from
                    // the chart's own price scale (green support, red resistance).
                    doodles = answer.priceLevels.compactMap { level in
                        let band = NormalizedRect(x: level.xStart, y: max(0.001, level.y - 0.002),
                                                  width: max(0.05, level.xEnd - level.xStart), height: 0.004)
                        // Chart answers take a while to write; the lines come from the
                        // price scale, so they stay valid well beyond the usual limit.
                        guard let rect = try? CoordinateMapper.globalQuartzRect(for: band, descriptor: capture.descriptor, maximumAge: 90)
                        else { return nil }
                        return DoodleMark(shape: .line, rect: rect, tone: level.kind == .support ? .teal : .coral,
                                          label: level.label, dotted: true)
                    }
                }
                if kind == .chartAnalysis, drawingNote == nil, doodles.isEmpty {
                    drawingNote = "Lines not drawn: the chart moved off-screen or changed. Ask again to draw them."
                }
                let shownAnswer = drawingNote.map { answer.answer + "\n\n(" + $0 + ")" } ?? answer.answer
                if kind == .howTo, !answer.guideSteps.isEmpty {
                    // Step-by-step guide: a numbered panel, with an arrow on each
                    // step's control while it's visible on the captured screen.
                    let tones: [DoodleTone] = [.violet, .teal, .amber, .coral]
                    let stepMarks: [DoodleMark?] = answer.guideSteps.enumerated().map { index, step in
                        guard displayUnchanged, let target = step.target,
                              let rect = try? CoordinateMapper.globalQuartzRect(for: target, descriptor: capture.descriptor,
                                                                                 maximumAge: Self.markMaximumAge) else { return nil }
                        return DoodleMark(shape: .arrow, rect: rect, from: index == 0 && !inChat ? capturePoint : nil,
                                          tone: tones[index % tones.count], label: step.title, step: index + 1)
                    }
                    let lessonSteps = answer.guideSteps.enumerated().map { index, step in
                        VisualExplanationStep(
                            title: step.title,
                            explanation: (step.explanation.isEmpty ? step.title : step.explanation)
                                + (stepMarks[index] == nil && index > 0
                                    ? "\n\nDo the previous step, then tap “Next screen” so Bibbles can point to this one."
                                    : ""),
                            strokes: [], labels: [])
                    }
                    let lesson = VisualExplanation(title: "Step-by-step guide", steps: lessonSteps)
                    if let chatConversationID { chatStore.completeScreenQuestion(answer.answer, in: chatConversationID) }
                    else { chatStore.recordExchange(userText: question, assistantText: answer.answer) }
                    interaction.rememberAnswer(answer.answer)
                    speakLocalAnswerIfNeeded(answer.guideSteps.first.map { "Step 1: " + $0.explanation } ?? answer.answer)
                    overlay.hide()
                    targetHighlight.hide()
                    let stepTitles = answer.guideSteps.map(\.title)
                    visualExplanation.show(lesson, provenance: "Current screen",
                        avoiding: stepMarks.compactMap { $0 }.first?.rect,
                        onStep: { [weak self] index in
                            guard let self else { return false }
                            guard stepMarks.indices.contains(index), let mark = stepMarks[index] else {
                                self.targetHighlight.hide()
                                return true // this step's control isn't on the captured screen
                            }
                            let age = Date().timeIntervalSince(capture.descriptor.capturedAt)
                            guard self.screenQuestionGeneration == generation, age >= 0, age < 120 else {
                                self.targetHighlight.hide()
                                return false
                            }
                            self.targetHighlight.showGuidance([mark], durationNanoseconds: 30_000_000_000)
                            return true
                        }, onRefresh: { [weak self] in
                            guard let self else { return }
                            // Continue from where the user is now, on the new screen.
                            let reached = self.visualExplanation.player.index
                            let done = stepTitles.prefix(max(reached, 1)).enumerated()
                                .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; ")
                            self.visualExplanation.hide()
                            self.targetHighlight.hide()
                            self.understandScreen(
                                question: question + " (I have already done: \(done). Guide me from the next step on the current screen.)",
                                cursor: capturePoint)
                        }, refreshTitle: "Next screen")
                    return
                }
                // Tutor-style explanation: draw each part as it is explained.
                if speakThisAnswer, voiceRepliesEnabled, !shouldSpeakNextAnswer { shouldSpeakNextAnswer = true }
                let scrolledSinceCapture = hotkeys.lastScrollAt > capture.descriptor.capturedAt
                Diagnostics.log("screen_answer", [
                    "kind": "\(kind)", "walkthroughSteps": answer.walkthrough.count,
                    "stepsWithMarks": answer.walkthrough.filter { $0.mark != nil }.count,
                    "annotations": answer.annotations.count, "lesson": answer.visualExplanation != nil,
                    "seconds": Int(Date().timeIntervalSince(capture.descriptor.capturedAt)),
                    "displayUnchanged": displayUnchanged, "scrolled": scrolledSinceCapture,
                    "inChat": inChat, "speak": shouldSpeakNextAnswer, "model": answer.model])
                if kind == .general, displayUnchanged, !scrolledSinceCapture, answer.walkthrough.count >= 2,
                   runWalkthrough(answer, capture: capture, question: question, chatConversationID: chatConversationID) {
                    return
                }
                // Not on screen: for files and folders, look on the Mac instead.
                let opening = answer.answer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let notOnScreen = opening.hasPrefix("not on screen") || opening.hasPrefix("no,")
                    || opening.hasPrefix("no.") || opening.hasPrefix("no ")
                if kind == .findControl, doodles.isEmpty, notOnScreen, !inChat,
                   IntentRouter.isLocateRequest(question), IntentRouter.mentionsFileItem(question) {
                    targetHighlight.hide()
                    performFileAction("Find this file or folder on my Mac: " + question,
                                      lead: "It's not on your screen, so I searched your Mac.",
                                      allowedTools: ["find_files"])
                    return
                }
                // One item: a simple answer with an arrow. Several: a step panel.
                if kind == .findControl, doodles.count > 1 {
                    let steps = doodles.enumerated().map { index, mark in
                        VisualExplanationStep(title: mark.label ?? "Visible control \(index + 1)",
                            explanation: index == 0 ? String(answer.answer.prefix(800)) : "This is another relevant control in the captured screen. Refresh after changing the screen to locate the next step.",
                            strokes: [], labels: [])
                    }
                    let lesson = VisualExplanation(title: "Follow the screen", steps: steps)
                    if let chatConversationID { chatStore.completeScreenQuestion(answer.answer, in: chatConversationID) }
                    else { chatStore.recordExchange(userText: question, assistantText: answer.answer) }
                    interaction.rememberAnswer(answer.answer)
                    speakLocalAnswerIfNeeded(answer.answer)
                    overlay.hide()
                    let marks = doodles
                    visualExplanation.show(lesson, provenance: "Current screen · refresh after each action", avoiding: marks.first?.rect,
                        onStep: { [weak self] index in
                            guard let self else { return false }
                            let age = Date().timeIntervalSince(capture.descriptor.capturedAt)
                            let layoutMatches = NSScreen.screens.contains { screen in
                                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                                return number?.uint32Value == capture.descriptor.displayID && screen.frame == capture.descriptor.displayFrameInQuartzPoints
                            }
                            guard self.screenQuestionGeneration == generation, age >= 0, age < Self.markMaximumAge, layoutMatches, marks.indices.contains(index) else {
                                self.targetHighlight.hide()
                                return false
                            }
                            self.targetHighlight.showGuidance([marks[index]], durationNanoseconds: UInt64(max(3, Self.markMaximumAge - age) * 1_000_000_000))
                            return true
                        }, onRefresh: { [weak self] in
                            guard let self else { return }
                            self.visualExplanation.hide()
                            self.targetHighlight.hide()
                            self.understandScreen(question: question, cursor: capturePoint)
                        })
                    return
                }
                if doodles.isEmpty { targetHighlight.hide() }
                else {
                    targetHighlight.showGuidance(doodles, durationNanoseconds: answer.priceLevels.isEmpty
                        ? 12_000_000_000 : 45_000_000_000)
                }
                if let chatConversationID {
                    // Asked by voice with the chat open: still answer out loud,
                    // and never leave the "speak" flag for a later answer.
                    speakLocalAnswerIfNeeded(answer.answer)
                    interaction.rememberAnswer(answer.answer)
                    chatStore.completeScreenQuestion(answer.answer, in: chatConversationID)
                } else {
                    speakLocalAnswerIfNeeded(answer.answer)
                    chatStore.recordExchange(userText: question, assistantText: answer.answer)
                    showInSyncWithVoice { [weak self] in
                        guard let self else { return }
                        self.interaction.transition(to: .answer(shownAnswer))
                        self.interaction.modelLabel = ClaudeAPI.answeredByLabel() ?? ClaudeAPI.taskLabel(for: answer.model)
                        self.overlay.showNearCursor(avoiding: self.targetHighlight.visibleBounds)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                shouldSpeakNextAnswer = false
                targetHighlight.hide()
                if let chatConversationID {
                    chatStore.failScreenQuestion(error, in: chatConversationID)
                } else {
                    interaction.transition(to: .failed(error.localizedDescription))
                    overlay.showNearCursor()
                }
            }
        }
    }

    private func runAcousticSelfTest() async {
        selfTestRunning = true
        let phrases = [
            "Explain why this React component is re-rendering.",
            "Ye pointer wrong coordinate par kyun render ho raha hai?",
            "Is WebSocket connection ko persistent rakho.",
            "ScreenCaptureKit crop ka backing scale factor check karo.",
            "Push to talk release ke baad transcript latency measure karo."
        ]

        for phrase in phrases {
            latency.clear()
            transcriptVisibleThisTurn = false
            latency.begin("shortcut_to_overlay")
            interaction.transition(to: .listening)
            overlay.showNearCursor()
            latency.end("shortcut_to_overlay")
            guard await speech.begin(mode: .command) else { break }

            do {
                try await speakForSelfTest(phrase)
                try? await Task.sleep(nanoseconds: 250_000_000)
                beginReleaseLatency()
                await withCheckedContinuation { continuation in
                    selfTestContinuation = continuation
                    Task { await speech.finish() }
                }
            } catch {
                try? error.localizedDescription.write(
                    toFile: "/tmp/bibbles-selftest-error.txt",
                    atomically: true,
                    encoding: .utf8
                )
                break
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        selfTestRunning = false
        await speech.shutdown()
        NSApp.terminate(nil)
    }

    private func runScreenSelfTest() async {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            try? "Screen Recording permission was not granted.".write(
                toFile: "/tmp/bibbles-screen-selftest-error.txt",
                atomically: true,
                encoding: .utf8
            )
            NSApp.terminate(nil)
            return
        }

        let startedAt = ContinuousClock.now
        do {
            let capture = try await screenCapture.captureCursorCrop()
            let observations = try await ocr.recognizeText(in: capture.image)
            let elapsed = startedAt.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1_000
                + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            let payload: [String: Any] = [
                "width": capture.image.width,
                "height": capture.image.height,
                "ocrRegionCount": observations.count,
                "captureAndOCRMilliseconds": milliseconds,
                "displayID": capture.descriptor.displayID
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/bibbles-screen-selftest.json"), options: .atomic)
            }
        } catch {
            try? error.localizedDescription.write(
                toFile: "/tmp/bibbles-screen-selftest-error.txt",
                atomically: true,
                encoding: .utf8
            )
        }
        NSApp.terminate(nil)
    }

    private func runVisionSelfTest() async {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            try? "Screen Recording permission was not granted.".write(
                toFile: "/tmp/bibbles-vision-selftest-error.txt",
                atomically: true,
                encoding: .utf8
            )
            NSApp.terminate(nil)
            return
        }

        let startedAt = ContinuousClock.now
        do {
            let capture = try await screenCapture.captureCursorCrop()
            let observations = try await ocr.recognizeText(in: capture.image)
            let ocrAt = ContinuousClock.now
            let answer = try await makeGroundingCoordinator().ground(VisionGroundingRequest(
                question: "Identify the most relevant visible UI target near the cursor. If there is one, return its location.",
                image: capture.image,
                ocr: observations,
                descriptor: capture.descriptor
            ))
            let completedAt = ContinuousClock.now
            let targetIsSafe: Bool
            if let target = answer.target {
                _ = try CoordinateMapper.globalQuartzRect(
                    for: target,
                    descriptor: capture.descriptor,
                    now: Date(),
                    maximumAge: 10
                )
                targetIsSafe = true
            } else {
                targetIsSafe = false
            }
            let payload: [String: Any] = [
                "captureAndOCRMilliseconds": milliseconds(startedAt.duration(to: ocrAt)),
                "groundingMilliseconds": milliseconds(ocrAt.duration(to: completedAt)),
                "totalMilliseconds": milliseconds(startedAt.duration(to: completedAt)),
                "ocrRegionCount": observations.count,
                "model": answer.model,
                "confidence": answer.confidence,
                "targetReturned": answer.target != nil,
                "targetMappedSafely": targetIsSafe,
                "imagePersisted": false
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: "/tmp/bibbles-vision-selftest.json"), options: .atomic)
        } catch {
            try? error.localizedDescription.write(
                toFile: "/tmp/bibbles-vision-selftest-error.txt",
                atomically: true,
                encoding: .utf8
            )
        }
        NSApp.terminate(nil)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func beginReleaseLatency() {
        latency.begin("ptt_release_to_first_update")
        if transcriptVisibleThisTurn {
            latency.end("ptt_release_to_first_update")
        }
        latency.begin("ptt_release_to_final")
    }

    /// The self-test speaks through the same voice too, so Bibbles never uses the
    /// Mac's built-in voice.
    private func speakForSelfTest(_ phrase: String) async throws {
        if case .failure(let error) = await voiceReply.speakAndWait(phrase) { throw error }
    }

    private func scheduleDismissal(afterNanoseconds: UInt64 = 2_500_000_000) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: afterNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.overlay.hide()
            self.interaction.cancel()
        }
    }

    private func recordSuccessfulDictation(_ output: String) {
        let seconds = dictationSpokenSeconds
            ?? dictationBeganAt.map { Date().timeIntervalSince($0) }
            ?? 0
        ProductAnalytics.shared.track(.dictationCompleted)
        usageMetrics.recordDictation(characterCount: output.count, spokenSeconds: seconds)
        dictationBeganAt = nil
        dictationSpokenSeconds = nil
    }

    private func dismissPanels() {
        stopWalkthrough()
        cancelContextPreparation()
        circleFocus.cancel()
        focusCaptureTask?.cancel()
        focusCaptureTask = nil
        focusPoint = nil
        firstRunTutorial.hide()
        pendingWriteTarget = nil
        pendingEdit = nil
        formFillTask?.cancel()
        formFillTask = nil
        speechTurnIsActive = false
        voiceReply.stop()
        shouldSpeakNextAnswer = false
        voiceMeter.end()
        dismissTask?.cancel()
        screenQuestionTask?.cancel()
        screenQuestionTask = nil
        screenQuestionGeneration = UUID()
        chatStore.cancel(showStatus: false)
        if let activeScreenChatID { chatStore.cancelScreenQuestion(in: activeScreenChatID) }
        activeScreenChatID = nil
        speechStartTask?.cancel()
        speechStartTask = nil
        reopenChatWhenNearNotch = chatPanel.isVisible
        hotkeys.suppressNotchUntilExit()
        notchPill.suppressHoverUntilExit()
        taskHistory.hide()
        chatPanel.hide()
        composer.hide()
        visualExplanation.hide()
        overlay.hide()
        targetHighlight.hide()
        liveDictationSession?.cancel()
        liveDictationSession = nil
        activeSpeechMode = .command
        dictationBeganAt = nil
        dictationSpokenSeconds = nil
        pointedLocation = nil
        Task { await speech.shutdown() }
        interaction.cancel()
    }

    private func updateEscapeCapture() {
        hotkeys.setEscapeCaptureEnabled(overlay.isVisible || chatPanel.isVisible || composer.isVisible
            || visualExplanation.isVisible || taskHistory.isVisible || firstRunTutorial.isVisible || circleFocus.isActive)
    }

    private func requestVisualExplanation(_ question: String) {
        stopWalkthrough()
        dismissTask?.cancel()
        chatStore.cancel(showStatus: false)
        screenQuestionTask?.cancel()
        if let activeScreenChatID { chatStore.cancelScreenQuestion(in: activeScreenChatID) }
        activeScreenChatID = nil
        visualExplanation.hide()
        targetHighlight.hide()
        voiceReply.stop()
        shouldSpeakNextAnswer = false
        pendingVisualQuestion = question
        let generation = UUID()
        screenQuestionGeneration = generation
        interaction.transition(to: .working("Planning a visual explanation…"))
        interaction.setActions(cancel: true)
        overlay.showNearCursor()
        screenQuestionTask = Task { [weak self] in
            guard let self else { return }
            defer { if screenQuestionGeneration == generation { screenQuestionTask = nil } }
            do {
                let provider = MessagesVisualExplanationProvider(apiKey: ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey))
                let lesson = try await provider.explain(question)
                try Task.checkCancellation()
                guard screenQuestionGeneration == generation else { return }
                pendingVisualQuestion = nil
                overlay.hide()
                chatStore.recordExchange(userText: question, assistantText: lesson.transcript)
                interaction.rememberAnswer(lesson.transcript)
                visualExplanation.show(lesson, provenance: "AI visual explanation")
            } catch {
                guard !Task.isCancelled, screenQuestionGeneration == generation else { return }
                interaction.transition(to: .failed(error.localizedDescription))
                interaction.setActions(retry: true)
                overlay.showNearCursor()
            }
        }
    }

    // MARK: Account isolation

    /// Each Bibbles account has its own chats on this Mac. When someone signs
    /// out, or a different account signs in, everything from the previous
    /// account is stopped and put away before the next one sees anything.
    private func observeAccountChanges() {
        _ = chatStore // load the signed-in account's chats now
        // A spoken question that starts an AI answer says a short "thinking" line.
        sendingObserver = chatStore.$isSending
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.playThinkingCueIfSpoken() }
        if voiceRepliesEnabled { voiceReply.prepareThinkingCues() }
        accountObserver = AccountSession.shared.$userID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] userID in self?.accountChanged(to: userID) }
    }

    private func accountChanged(to userID: String?) {
        let previous = chatStore.ownerID
        guard userID?.lowercased() != previous else { return }
        // Stop anything in flight and close panels showing the old account's content.
        dismissPanels()
        WorkMemory.shared.clear()
        interaction.forgetLastAnswer()
        let erase = previous.map { AccountSession.shared.deletedUserIDs.contains($0) } ?? false
        // The notch task list and chat window read the store, so they update by themselves.
        chatStore.switchAccount(to: userID, erasingPrevious: erase)
    }

    private func beginContextPreparation() -> UUID {
        cancelContextPreparation()
        return contextPreparationID
    }

    private func isCurrentContextPreparation(_ id: UUID) -> Bool {
        !Task.isCancelled && contextPreparationID == id
    }

    private func cancelContextPreparation() {
        pendingSelectionMark?.cancel()
        pendingSelectionMark = nil
        contextPreparationTask?.cancel()
        contextPreparationTask = nil
        contextPreparationID = UUID()
    }

    private func cancelCurrentOperation() {
        stopWalkthrough()
        cancelContextPreparation()
        circleFocus.cancel()
        focusCaptureTask?.cancel()
        focusCaptureTask = nil
        focusPoint = nil
        pendingWriteTarget = nil
        pendingEdit = nil
        formFillTask?.cancel()
        formFillTask = nil
        voiceReply.stop()
        shouldSpeakNextAnswer = false
        screenQuestionTask?.cancel()
        screenQuestionTask = nil
        if let activeScreenChatID { chatStore.cancelScreenQuestion(in: activeScreenChatID) }
        activeScreenChatID = nil
        targetHighlight.hide()
        chatStore.cancel()
        interaction.transition(to: .failed("Response cancelled. Your question is preserved."))
        interaction.setActions(retry: true)
        overlay.showNearCursor()
    }

    // MARK: Screen walkthrough

    private func stopWalkthrough() {
        walkthroughID = UUID()
        walkthroughTask?.cancel()
        walkthroughTask = nil
        walkthroughMarks.removeAll()
        walkthroughSays.removeAll()
        walkthroughShownThrough = -1
        targetHighlight.endWalkthrough()
    }

    /// Explains the screen one part at a time: each step's mark is drawn the
    /// moment its sentence is spoken (or shown), earlier marks stay, and the
    /// last step usually covers the whole thing. Returns false when no step
    /// could be placed on the screen (the ordinary answer is used instead).
    private func runWalkthrough(_ answer: GroundedAnswer, capture: ScreenCaptureResult, question: String,
                                chatConversationID: UUID?) -> Bool {
        let tones: [DoodleTone] = [.violet, .teal, .amber, .coral]
        let descriptor = capture.descriptor
        func point(_ p: CGPoint) -> CGPoint? {
            let side: CGFloat = 0.0005
            let box = NormalizedRect(x: min(max(p.x - side / 2, 0), 1 - side), y: min(max(p.y - side / 2, 0), 1 - side),
                                     width: side, height: side)
            guard let rect = try? CoordinateMapper.globalQuartzRect(for: box, descriptor: descriptor, maximumAge: Self.walkthroughMarkAge)
            else { return nil }
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        let marks: [DoodleMark?] = answer.walkthrough.enumerated().map { index, step in
            guard let mark = step.mark else { return nil }
            let tone = tones[index % tones.count]
            if !mark.points.isEmpty {
                let points = mark.points.compactMap(point)
                guard points.count >= 2 else { return nil }
                let xs = points.map(\.x), ys = points.map(\.y)
                let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 1), height: max(ys.max()! - ys.min()!, 1))
                return DoodleMark(shape: .line, rect: bounds, tone: tone, label: mark.label, step: index + 1, points: points)
            }
            guard let target = mark.target,
                  let rect = try? CoordinateMapper.globalQuartzRect(for: target, descriptor: descriptor, maximumAge: Self.walkthroughMarkAge)
            else { return nil }
            return DoodleMark(shape: mark.shape, rect: rect, tone: tone, label: mark.label, step: index + 1)
        }
        Diagnostics.log("walkthrough", ["event": "start", "steps": marks.count, "placed": marks.compactMap { $0 }.count])
        guard marks.contains(where: { $0 != nil }) else { return false }

        let text = answer.answer
        interaction.rememberAnswer(text)
        if let chatConversationID {
            chatStore.completeScreenQuestion(text, in: chatConversationID)
        } else {
            chatStore.recordExchange(userText: question, assistantText: text)
            interaction.transition(to: .answer(text))
            interaction.modelLabel = ClaudeAPI.answeredByLabel() ?? ClaudeAPI.taskLabel(for: answer.model)
            let all = marks.compactMap { $0?.rect }.reduce(CGRect.null) { $0.union($1) }
            overlay.showNearCursor(avoiding: all.isNull ? nil : all.insetBy(dx: -24, dy: -24))
        }

        stopWalkthrough()
        let id = UUID()
        walkthroughID = id
        walkthroughMarks = marks
        walkthroughSays = answer.walkthrough.map(\.say)
        walkthroughShownThrough = -1
        let count = marks.count
        let speaking = shouldSpeakNextAnswer
        if speaking {
            shouldSpeakNextAnswer = false
            voiceReply.speakSteps(walkthroughSays) { [weak self] index in self?.showWalkthroughStep(index, id: id) }
        }
        walkthroughTask = Task { @MainActor [weak self] in
            if speaking {
                // Follow the voice; if it stops early (error or no audio),
                // finish the remaining steps on a reading timer.
                while !Task.isCancelled, self?.voiceReply.isActive == true {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            while !Task.isCancelled, let me = self, me.walkthroughID == id, me.walkthroughShownThrough < count - 1 {
                let next = me.walkthroughShownThrough + 1
                me.showWalkthroughStep(next, id: id)
                guard next < count - 1 else { break }
                let words = Double(me.walkthroughSays[next].split(whereSeparator: \.isWhitespace).count)
                try? await Task.sleep(nanoseconds: UInt64(max(2.5, words / 2.8) * 1_000_000_000))
            }
            if let me = self, me.walkthroughID == id { me.walkthroughTask = nil }
        }
        return true
    }

    /// Draws step `index` of the current walkthrough (earlier marks stay).
    private func showWalkthroughStep(_ index: Int, id: UUID) {
        guard walkthroughID == id, index > walkthroughShownThrough, walkthroughMarks.indices.contains(index) else { return }
        walkthroughShownThrough = index
        // Only a step with its own mark changes the drawing.
        guard walkthroughMarks[index] != nil else { return }
        let isLast = index == walkthroughMarks.count - 1
        targetHighlight.showWalkthrough(walkthroughMarks.prefix(index + 1).compactMap { $0 },
                                        durationNanoseconds: isLast ? 20_000_000_000 : 25_000_000_000)
    }

    /// Once per spoken question, while the AI works: "Ok, let me think first",
    /// "Give me a moment" or "Let me look at this properly" (saved files).
    private func playThinkingCueIfSpoken() {
        guard shouldSpeakNextAnswer, voiceRepliesEnabled, !thinkingCuePlayed else { return }
        thinkingCuePlayed = true
        voiceReply.playThinkingCue()
    }

    /// A spoken answer: show the card when its voice starts, so text and voice
    /// begin together. Not spoken (typed, voice off): show it now. If the
    /// voice fails or is slow, the text shows after 2.5 s anyway; Escape or a
    /// new question (voice stopped) drops a held answer.
    private func showInSyncWithVoice(_ show: @escaping () -> Void) {
        guard voiceReply.isActive, !voiceReply.hasStartedCurrent, stoppedWaitingFor != voiceReply.generationID else {
            heldAnswer = nil
            heldAnswerTimeout?.cancel()
            heldAnswerTimeout = nil
            show()
            return
        }
        // The latest version of the answer wins (streamed updates).
        heldAnswer = (show, voiceReply.generationID)
        guard heldAnswerTimeout == nil else { return }
        heldAnswerTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.stoppedWaitingFor = self.voiceReply.generationID
            self.releaseHeldAnswer()
        }
    }

    private func releaseHeldAnswer() {
        heldAnswerTimeout?.cancel()
        heldAnswerTimeout = nil
        guard let held = heldAnswer else { return }
        heldAnswer = nil
        guard held.voice == voiceReply.generationID else { return }
        held.show()
    }

    private func speakLocalAnswerIfNeeded(_ answer: String) {
        guard shouldSpeakNextAnswer else { return }
        shouldSpeakNextAnswer = false
        voiceReply.speak(answer)
    }

    private func toggleVoice(_ answer: String) {
        if voiceReply.isActive {
            shouldSpeakNextAnswer = false
            voiceReply.stop()
        } else {
            // The text is already on screen, so don't hide it while reading.
            voiceReply.speak(answer)
        }
    }

    /// Each task started with the hotkey or the type box gets its own
    /// conversation, so the chat window shows one task per conversation —
    /// matching the notch task history. A quick follow-up ("and the next
    /// one?", "explain more") continues the task before it. Inside the chat
    /// window, messages always continue the open conversation.
    private func beginTaskConversationIfNeeded(for transcript: String) {
        guard !chatPanel.isVisible, !chatStore.isSending, chatStore.activityMessage == nil else { return }
        guard let current = chatStore.selectedConversation, !current.messages.isEmpty else { return }
        let recent = Date().timeIntervalSince(current.updatedAt) < 5 * 60
        if recent && (TaskHistory.isFollowUp(transcript)
            || (EditRequest.isEdit(transcript) && WorkMemory.shared.latest(preferring: lastExternalApp) != nil)) { return }
        chatStore.createConversation()
    }

    @objc private func openSettings() {
        dismissTask?.cancel()
        taskHistory.hide()
        overlay.hide()
        settingsWindow.show()
    }

    @objc private func toggleNotchHistory() {
        notchHistoryEnabled.toggle()
        if notchHistoryEnabled {
            notchPill.show()
        } else {
            taskHistory.hide()
            notchPill.hide()
        }
        updateMenuBarIcon()
    }

    private func showTaskHistoryFromNotch() {
        guard notchHistoryEnabled, !chatPanel.isVisible, !taskHistory.isVisible,
              notchPill.isOnActiveSpace else { return }   // hidden in full-screen apps
        taskHistory.showBelowNotch(anchor: notchPill.frame)
    }

    @objc private func toggleVoiceReplies() {
        voiceRepliesEnabled.toggle()
        if !voiceRepliesEnabled {
            shouldSpeakNextAnswer = false
            voiceReply.stop()
        }
    }

    private func retryLastOperation() {
        if let pendingVisualQuestion { requestVisualExplanation(pendingVisualQuestion); return }
        guard chatStore.retryLast() else { return }
        interaction.transition(to: .working("Retrying…"))
        interaction.setActions(cancel: true)
        overlay.showNearCursor()
    }

    private func useTranscriptAnyway() {
        let transcript = latestPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        interaction.setActions()
        if lastFailedSpeechMode == .dictation {
            let output = DictationProcessor.process(
                transcript,
                mode: dictationPreferences.mode,
                corrections: correctionStore.corrections
            )
            do {
                try textInserter.insert(output)
                recordSuccessfulDictation(output)
                interaction.transition(to: .transcript(output, isFinal: true))
                scheduleDismissal()
            } catch {
                interaction.transition(to: .failed(error.localizedDescription))
            }
        } else {
            interaction.transition(to: .transcript(transcript, isFinal: true))
            dispatch(intentRouter.route(transcript: transcript, mode: .command), transcript: transcript)
        }
        overlay.showNearCursor()
    }

    /// Finds where some text is shown on screen (for apps that don't report
    /// their selection's position): reads the screen and matches its lines.
    private func locateOnScreen(_ text: String, near cursor: CGPoint) async -> CGRect? {
        let wanted = text.lowercased().filter { $0.isLetter || $0.isNumber }
        guard wanted.count >= 6, CGPreflightScreenCaptureAccess(),
              let capture = try? await screenCapture.captureDisplayOverview(cursor: cursor),
              let lines = try? await ocr.recognizeText(in: capture.fullResolution ?? capture.image, accurate: true) else { return nil }
        let matched = lines.filter { line in
            let value = line.text.lowercased().filter { $0.isLetter || $0.isNumber }
            return value.count >= 6 && (wanted.contains(value) || (value.contains(wanted) && wanted.count >= 10))
        }
        guard let first = matched.first else { return nil }
        let union = matched.dropFirst().reduce(CGRect(x: first.normalizedRect.x, y: first.normalizedRect.y,
                                                      width: first.normalizedRect.width, height: first.normalizedRect.height)) {
            $0.union(CGRect(x: $1.normalizedRect.x, y: $1.normalizedRect.y, width: $1.normalizedRect.width, height: $1.normalizedRect.height))
        }
        let box = NormalizedRect(x: union.minX, y: union.minY, width: union.width, height: union.height)
        return try? CoordinateMapper.globalQuartzRect(for: box, descriptor: capture.descriptor, maximumAge: 60)
    }

    /// The OCR text closest to the pointer, if it is really near it.
    nonisolated static func textNearest(_ point: CGPoint, in observations: [OCRObservation]) -> OCRObservation? {
        func gap(_ rect: NormalizedRect) -> CGFloat {
            let dx = max(rect.x - point.x, 0, point.x - (rect.x + rect.width))
            let dy = max(rect.y - point.y, 0, point.y - (rect.y + rect.height))
            return (dx * dx + dy * dy).squareRoot()
        }
        guard let best = observations.min(by: { gap($0.normalizedRect) < gap($1.normalizedRect) }),
              gap(best.normalizedRect) < 0.04 else { return nil }
        return best
    }

    private func focusedContext(for transcript: String) async -> FocusedContextSnapshot? {
        guard intentRouter.shouldUseFocusedText(for: transcript) else { return nil }
        return await focusedContextReader.snapshot()
    }

    @objc private func openChat() {
        dismissTask?.cancel()
        reopenChatWhenNearNotch = false
        taskHistory.hide()
        overlay.hide()
        chatPanel.show()
    }

    @objc private func undoScreenDrawing() {
        targetHighlight.undoDrawing()
    }

    @objc private func clearScreenDrawings() {
        targetHighlight.hide()
    }

    @objc private func showLastAnswer() {
        guard interaction.showAgain() else { return }
        dismissTask?.cancel()
        overlay.showNearCursor()
    }

    // MARK: Tool Gate (developer menu)

    #if BIBBLES_DEVELOPER
    @objc private func toggleToolGate() {
        DeveloperControls.shared.setToolGate(!ToolGate.isEnabled)
        showDeveloperNote("\(ToolGateStrings.menuGate): \(ToolGate.isEnabled ? "On" : "Off")")
    }

    @objc private func toggleToolGateLog() {
        DeveloperControls.shared.setRecordingLog(!ToolGateLog.shared.isRecording)
        showDeveloperNote("\(ToolGateStrings.menuRecordLog): \(ToolGateLog.shared.isRecording ? "On" : "Off")")
    }

    @objc private func copyToolGateLog() {
        let copied = DeveloperControls.shared.copyLog()
        showDeveloperNote(copied ? "\(ToolGateStrings.logCopied) (\(ToolGateLog.shared.entries.count))" : ToolGateStrings.logEmpty)
    }

    @objc private func clearToolGateLog() {
        DeveloperControls.shared.clearLog()
        showDeveloperNote(ToolGateStrings.menuClearLog)
    }

    private func showDeveloperNote(_ text: String) {
        interaction.transition(to: .transcript(text, isFinal: true))
        overlay.showNearCursor()
        scheduleDismissal()
    }
    #endif

    @objc private func copyLastAnswer() {
        guard let answer = interaction.lastAnswer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PlainText.clean(answer, forAppBundleID: nil), forType: .string)
    }

    private func closeChatPanel() {
        reopenChatWhenNearNotch = true
        hotkeys.suppressNotchUntilExit()
        chatPanel.hide()
    }

    @objc private func openComposer() {
        interaction.transition(to: .composing)
        composer.showNearCursor()
        if notchHistoryEnabled { notchPill.interactionDidBegin() }
    }

    @objc private func openQuickWebSearch() {
        interaction.transition(to: .composing)
        composer.showNearCursor(searchWeb: true)
        if notchHistoryEnabled { notchPill.interactionDidBegin() }
    }

    @objc private func openAccessibilityPermission() {
        PermissionService.requestAccessibilityPrompt()
        PermissionService.openAccessibilitySettings()
    }

    private func showGettingStartedIfNeeded() {
        guard TutorialLaunchPolicy.claimFirstPresentation() else { return }
        showSetupTutorial()
    }

    @objc private func showSetupTutorial() {
        firstRunTutorial.show()
    }

    @objc private func showGettingStarted() {
        welcomeWindow.show()
    }

    @objc private func showPermissionStatus() {
        let status = PermissionService.snapshot()
        let microphone: String
        switch status.microphone {
        case .authorized: microphone = "Granted"
        case .denied, .restricted: microphone = "Denied"
        case .notDetermined: microphone = "Not requested"
        @unknown default: microphone = "Unknown"
        }
        let alert = NSAlert()
        alert.messageText = "Bibbles permissions"
        alert.informativeText = "Accessibility: \(status.accessibility ? "Granted" : "Not granted")\nMicrophone: \(microphone)\nScreen Recording: \(status.screenRecording ? "Granted" : "Not granted")"
        alert.addButton(withTitle: "OK")
        let needsPermission = !status.accessibility || status.microphone != .authorized || !status.screenRecording
        if needsPermission { alert.addButton(withTitle: "Request Missing Permissions") }
        if alert.runModal() == .alertSecondButtonReturn {
            if !status.accessibility { PermissionService.requestAccessibilityPrompt() }
            if status.microphone != .authorized {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            if !status.screenRecording { _ = PermissionService.requestScreenRecording() }
        }
    }

    private func trackExternalApps() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastExternalApp = front
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            Task { @MainActor in
                if self?.lastExternalApp?.processIdentifier != app.processIdentifier { self?.stopWalkthrough() }
                self?.lastExternalApp = app
            }
        }
    }

    /// Creates a folder or renames a file/folder from a spoken request.
    /// Renames are confirmed first; nothing is ever deleted, moved or overwritten.
    #if BIBBLES_DEVELOPER
    /// The Files agent: preview first, nothing changes before Start; Done · Undo
    /// for 30 minutes (also from task history and the menu).
    private func startFilesAgent(_ transcript: String, layer: String) {
        pendingVisualQuestion = nil
        beginTaskConversationIfNeeded(for: transcript)
        let speak = shouldSpeakNextAnswer && voiceRepliesEnabled
        shouldSpeakNextAnswer = false
        voiceReply.stop()
        dismissTask?.cancel()
        overlay.hide()
        let session = FilesAgentSession(text: transcript, layer: layer)
        let label = session.strings.label
        session.onFinished = { [weak self] summary in
            guard let self else { return }
            self.chatStore.recordExchange(userText: transcript, assistantText: summary)
            self.interaction.modelLabel = label
            if speak { self.voiceReply.speak(AgentSpeech.short(summary)) }
        }
        activeFilesSession = session
        activeScreenSession = nil
        agentPanel.show(session)
        session.start()
    }

    /// The Screen agent works in the app the user was in (never in Bibbles).
    private func startScreenAgent(_ transcript: String, layer: String) {
        pendingVisualQuestion = nil
        beginTaskConversationIfNeeded(for: transcript)
        let speak = shouldSpeakNextAnswer && voiceRepliesEnabled
        shouldSpeakNextAnswer = false
        voiceReply.stop()
        dismissTask?.cancel()
        overlay.hide()
        let session = ScreenAgentSession(text: transcript, app: lastExternalApp, inserter: textInserter, layer: layer)
        let label = session.strings.label
        session.onFinished = { [weak self] summary in
            guard let self else { return }
            self.chatStore.recordExchange(userText: transcript, assistantText: summary)
            self.interaction.modelLabel = label
            if speak { self.voiceReply.speak(AgentSpeech.short(summary)) }
        }
        // Asked by voice: say when it waits, so "continue" can be said back.
        session.onWaiting = { [weak self, weak session] in
            guard speak, let self, let session else { return }
            self.voiceReply.speak(session.round == 1 ? "Ready. Say continue to start, or stop." : "Ready for the next part. Say continue.")
        }
        activeScreenSession = session
        activeFilesSession = nil
        agentPanel.show(session)
        session.start()
    }

    /// "stop" / "continue" said while an agent task is open. Anything else is a new request.
    private func handleAgentVoiceCommand(_ transcript: String) -> Bool {
        guard let command = AgentVoiceCommand.parse(transcript) else { return false }
        var handled = false
        if let session = activeScreenSession, session.isActive {
            handled = session.handle(command)
        } else if let session = activeFilesSession {
            handled = session.handle(command)
        }
        guard handled else { return false }
        shouldSpeakNextAnswer = false
        voiceReply.stop()
        dismissTask?.cancel()
        overlay.hide()
        return true
    }

    @objc private func undoLastAgentTask() {
        guard let session = AgentUndoRegistry.shared.latest else { return }
        agentPanel.show(session)
        session.undo()
    }
    #endif

    private func performFileAction(_ transcript: String, lead: String? = nil, allowedTools: Set<String>? = nil) {
        shouldSpeakNextAnswer = false
        voiceReply.stop()
        let key = ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey) ?? ""
        guard !key.isEmpty || LockScreenCommand.localPlan(for: transcript) != nil || MusicRequest.localPlan(transcript) != nil else {
            interaction.transition(to: .failed("Please sign in to Bibbles first."))
            overlay.showNearCursor()
            return
        }
        interaction.transition(to: .working("On it…"))
        interaction.setActions(cancel: true)
        overlay.showNearCursor()
        formFillTask?.cancel()
        formFillTask = Task { @MainActor [weak self] in
            do {
                var plan = try await CommandAgent.plan(command: transcript, apiKey: key)
                try Task.checkCancellation()
                guard let self else { return }
                // Only the tools this request may use, and the user confirms
                // anything lasting or anything they didn't clearly ask for.
                if let allowedTools {
                    plan = AgentPlan(calls: plan.calls.filter { allowedTools.contains($0.name) }, text: plan.text)
                }
                let toConfirm = plan.calls.filter { CommandAgent.needsConfirmation($0, command: transcript) }
                if !toConfirm.isEmpty, !self.confirmActions(toConfirm.map(CommandAgent.describe)) {
                    let reply = "Cancelled. Nothing was changed."
                    self.chatStore.recordExchange(userText: transcript, assistantText: reply)
                    self.interaction.transition(to: .transcript(reply, isFinal: true))
                    self.overlay.showNearCursor()
                    self.scheduleDismissal(afterNanoseconds: 2_500_000_000)
                    return
                }
                guard !plan.calls.isEmpty else {
                    // Claude explained it can't do this with the available tools.
                    let reply = [lead, plan.text.isEmpty ? "Bibbles can't do that yet." : plan.text]
                        .compactMap { $0 }.joined(separator: "\n")
                    self.chatStore.recordExchange(userText: transcript, assistantText: reply)
                    self.interaction.transition(to: .answer(reply))
                    self.interaction.setActions()
                    self.overlay.showNearCursor()
                    return
                }
                var messages: [String] = []
                var showsDetails = false
                for call in plan.calls {
                    try Task.checkCancellation()
                    do {
                        let result = try await CommandAgent.run(call) { old, new, place in
                            self.confirmRename(old, to: new, in: place)
                        }
                        try Task.checkCancellation()
                        messages.append(result.message)
                        showsDetails = showsDetails || result.showsDetails
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as LocalizedError {
                        messages.append(error.errorDescription ?? "Something went wrong.")
                        showsDetails = true
                    }
                }
                let message = ([lead].compactMap { $0 } + messages).joined(separator: "\n")
                self.chatStore.recordExchange(userText: transcript, assistantText: message)
                if showsDetails || messages.count > 1 || lead != nil {
                    self.interaction.transition(to: .answer(message))
                    self.interaction.setActions()
                    self.overlay.showNearCursor()
                } else {
                    self.interaction.transition(to: .transcript(message, isFinal: true))
                    self.overlay.showNearCursor()
                    self.scheduleDismissal(afterNanoseconds: 3_000_000_000)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.interaction.transition(to: .failed(error.localizedDescription))
                self.interaction.setActions()
                self.overlay.showNearCursor()
            }
        }
    }

    /// Asks before Bibbles carries out actions Claude chose.
    private func confirmActions(_ actions: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = actions.count == 1 ? "Do this?" : "Do these \(actions.count) things?"
        alert.informativeText = actions.map { "• " + $0 }.joined(separator: "\n")
        alert.addButton(withTitle: "Do It")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if let app = lastExternalApp, !app.isTerminated { app.activate(options: []) }
        return confirmed
    }

    private func confirmRename(_ oldName: String, to newName: String, in place: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rename “\(oldName)”?"
        alert.informativeText = "Bibbles will rename it to “\(newName)” in \(place)."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if let app = lastExternalApp, !app.isTerminated { app.activate(options: []) }
        return confirmed
    }

    /// Fixes the selected text, or the whole focused editor, in place, then
    /// explains every change (where it was and why it was wrong).
    private func fixText(_ transcript: String) {
        usageMeter.recordDeepTask()
        guard let target = lastExternalApp, !target.isTerminated else {
            interaction.transition(to: .failed("Click into the text you want fixed, then ask again."))
            overlay.showNearCursor()
            return
        }
        guard let key = ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey), !key.isEmpty else {
            interaction.transition(to: .failed("Please sign in to Bibbles first."))
            overlay.showNearCursor()
            return
        }
        let appName = target.localizedName ?? "your app"
        interaction.transition(to: .working("Reading your text…"))
        interaction.setActions(cancel: true)
        overlay.showNearCursor()
        let cursor = pointedLocation ?? NSEvent.mouseLocation
        formFillTask?.cancel()
        formFillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.composer.isVisible { self.composer.hide() }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                    target.activate(options: [])
                    try await Task.sleep(nanoseconds: 450_000_000)
                }
                // Read only what the app shares (the selection, or the editor's
                // text). Sending a whole document, or a screenshot, is asked first.
                var readSource = FixTextReader.readAccessible()
                let wantsScreenshot = ClaudeFixer.wantsScreenshot(for: transcript)
                if readSource?.scope != .selection || wantsScreenshot {
                    guard self.confirmSendingForFix(appName: appName, source: readSource, screenshot: wantsScreenshot) else {
                        self.interaction.transition(to: .transcript("Cancelled. Nothing was sent.", isFinal: true))
                        self.overlay.showNearCursor()
                        self.scheduleDismissal(afterNanoseconds: 2_500_000_000)
                        return
                    }
                    target.activate(options: [])
                    try await Task.sleep(nanoseconds: 450_000_000)
                    if readSource == nil { readSource = await FixTextReader.copyAll() }
                }
                guard let source = readSource else { throw TextFixError.nothingToFix }
                let screenshot = wantsScreenshot
                    ? try? await self.screenCapture.captureDisplayOverview(cursor: cursor).image : nil
                try Task.checkCancellation()
                self.interaction.transition(to: .working("Fixing it…"))
                let (result, model) = try await ClaudeFixer.fix(request: transcript, source: source, screenshot: screenshot,
                                                                appName: appName, apiKey: key)
                try Task.checkCancellation()
                let unchanged = result.fixedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    == source.text.trimmingCharacters(in: .whitespacesAndNewlines)
                var message = result.explanation
                if unchanged {
                    message = result.summary.isEmpty ? "Bibbles didn't find anything to fix." : result.summary
                } else {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                        target.activate(options: [])
                        try await Task.sleep(nanoseconds: 450_000_000)
                    }
                    if source.scope == .wholeText {
                        FixTextReader.press(0) // select all, so the fixed text replaces it
                        try await Task.sleep(nanoseconds: 120_000_000)
                    }
                    try self.textInserter.paste(result.fixedText)
                    message += "\n\nFixed in \(appName). Press ⌘Z there to undo."
                }
                self.chatStore.recordExchange(userText: transcript, assistantText: message)
                self.interaction.transition(to: .answer(message))
                self.interaction.modelLabel = ClaudeAPI.answeredByLabel() ?? ClaudeAPI.taskLabel(for: model)
                self.interaction.setActions()
                self.overlay.showNearCursor()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.interaction.transition(to: .failed(error.localizedDescription))
                self.interaction.setActions()
                self.overlay.showNearCursor()
            }
        }
    }

    /// Says exactly what will go to Claude before a fix sends more than the
    /// user's own selection. "Don't ask again" is remembered.
    private func confirmSendingForFix(appName: String, source: FixSource?, screenshot: Bool) -> Bool {
        let skipKey = "bibbles.fix.skipSendConfirmation"
        if UserDefaults.standard.bool(forKey: skipKey) { return true }
        var parts: [String] = []
        if source?.scope == .selection {
            parts.append("the text you selected")
        } else if let source {
            parts.append("all the text in this \(appName) editor (\(source.text.count) characters)")
        } else {
            parts.append("all the text in this \(appName) editor. Bibbles will select it and copy it, then put your clipboard back")
        }
        if screenshot { parts.append("a screenshot of your screen, so Claude can see the errors") }
        let alert = NSAlert()
        alert.messageText = "Send this to Claude to fix it?"
        alert.informativeText = "Bibbles will send " + parts.joined(separator: ", and ")
            + " to Anthropic's Claude API. Select just the part you want fixed to send less."
        alert.addButton(withTitle: "Send and Fix")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: skipKey) }
        return confirmed
    }

    private func writeFromScreen(_ transcript: String, into target: NSRunningApplication, apiKey: String) {
        let appName = target.localizedName ?? "your app"
        interaction.transition(to: .working("Reading your screen…"))
        interaction.setActions(cancel: true)
        overlay.showNearCursor()
        let cursor = pointedLocation ?? NSEvent.mouseLocation
        formFillTask?.cancel()
        formFillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.screenCapture.captureDisplayOverview(cursor: cursor, maximumLongEdgePixels: 2_000)
                try Task.checkCancellation()
                self.interaction.transition(to: .working("Writing it for \(appName)…"))
                let text = try await ScreenWriter.write(request: transcript, screenshot: capture.image,
                                                        appName: appName, apiKey: apiKey)
                try Task.checkCancellation()
                self.chatStore.recordExchange(userText: transcript, assistantText: text)
                self.pendingWriteRequest = transcript
                self.pendingEdit = nil
                self.interaction.rememberAnswer(text)
                self.typeAnswer(text, into: target)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.interaction.transition(to: .failed(error.localizedDescription))
                self.interaction.setActions()
                self.overlay.showNearCursor()
            }
        }
    }

    /// Asks Claude which text belongs in which box of the user's window
    /// (To, Subject, message body, …), then moves the cursor to each box and
    /// types it. Never presses Send.
    private func fillForm(_ transcript: String, in target: NSRunningApplication, fields: [FormField], apiKey: String) {
        let appName = target.localizedName ?? "your app"
        interaction.transition(to: .working("Filling it in for \(appName)…"))
        interaction.setActions(cancel: true)
        overlay.showNearCursor()
        formFillTask?.cancel()
        formFillTask = Task { @MainActor [weak self] in
            do {
                let plan = try await ClaudeFormPlanner.plan(
                    userRequest: transcript,
                    appName: appName,
                    fields: fields,
                    apiKey: apiKey
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard !plan.actions.isEmpty else {
                    self.interaction.transition(to: .failed(
                        plan.note ?? "Bibbles couldn't find a matching box. Click into the box you want and try again."
                    ))
                    self.interaction.setActions()
                    self.overlay.showNearCursor()
                    return
                }
                if self.composer.isVisible { self.composer.hide() }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                    target.activate(options: [])
                    try await Task.sleep(nanoseconds: 450_000_000)
                }
                let filled = await self.formFiller.fill(plan.actions, fields: fields)
                try Task.checkCancellation()
                let written = plan.actions.map(\.text).joined(separator: "\n\n")
                self.chatStore.recordExchange(userText: transcript, assistantText: written)
                if filled > 0 { WorkMemory.shared.remember(written, request: transcript, app: target) }
                self.interaction.rememberAnswer(written)
                if filled > 0 {
                    self.interaction.transition(to: .transcript(plan.note ?? "Filled in \(appName)", isFinal: true))
                    self.overlay.showNearCursor()
                    self.scheduleDismissal()
                } else {
                    // Couldn't type: show the text so it can be inserted manually.
                    self.interaction.transition(to: .answer(written))
                    self.interaction.setActions()
                    self.overlay.showNearCursor()
                }
            } catch is CancellationError {
                return
            } catch FormFillError.invalidPlan {
                // Couldn't map the request to boxes: write it at the cursor instead.
                guard let self, !Task.isCancelled else { return }
                self.pendingWriteTarget = target
                self.pendingWriteRequest = transcript
                self.pendingEdit = nil
                self.interaction.transition(to: .working("Writing it for \(appName)…"))
                self.overlay.showNearCursor()
                self.chatStore.send(transcript, writeMode: true)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.interaction.transition(to: .failed(error.localizedDescription))
                self.interaction.setActions()
                self.overlay.showNearCursor()
            }
        }
    }

    /// Rewrites something already written and replaces it in place. Uses the
    /// highlighted text if there is one, otherwise what Bibbles wrote most
    /// recently (its work memory). Returns false when there is nothing to
    /// rewrite, so the request is handled normally.
    private func startEdit(_ transcript: String) -> Bool {
        let target = lastExternalApp.flatMap { $0.isTerminated ? nil : $0 }
        let memory = WorkMemory.shared.latest(preferring: target)
        // Without memory, only take over when the request clearly names a text
        // ("replace this story") that may be highlighted.
        guard memory != nil || EditRequest.namesText(transcript) || intentRouter.shouldUseFocusedText(for: transcript) else {
            return false
        }
        guard ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey)?.isEmpty == false else { return false }
        let app = target ?? memory.flatMap { NSRunningApplication(processIdentifier: $0.appPID) }
        shouldSpeakNextAnswer = false
        voiceReply.stop()
        interaction.transition(to: .working("Rewriting it for \(app?.localizedName ?? memory?.appName ?? "your app")…"))
        interaction.setActions(cancel: true)
        overlay.showNearCursor()
        let preparation = beginContextPreparation()
        contextPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.focusedContextReader.snapshot()
            guard self.isCurrentContextPreparation(preparation) else { return }
            let selection = snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.pendingWriteTarget = app
            self.pendingWriteRequest = transcript
            let original: String
            if !selection.isEmpty {
                original = selection
                self.pendingEdit = PendingEdit(original: nil)
            } else if let memory {
                original = memory.text
                self.pendingEdit = PendingEdit(original: memory.text)
            } else {
                // Nothing to rewrite after all: write a new version at the cursor.
                self.pendingEdit = nil
                self.chatStore.send(transcript, writeMode: true)
                return
            }
            let context = FocusedContextSnapshot(applicationName: app?.localizedName ?? snapshot.applicationName,
                                                 selectedText: String(original.prefix(6_000)))
            self.chatStore.send(transcript, focusedContext: context, editing: true)
        }
        return true
    }

    /// Types an answer into the user's app: switches back to it if needed,
    /// pastes into the focused text box, and restores the clipboard.
    private func typeAnswer(_ text: String, into target: NSRunningApplication?) {
        let answer = PlainText.clean(text, forAppBundleID: target?.bundleIdentifier)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        guard let target, !target.isTerminated else {
            interaction.transition(to: .failed("Click into the text box where you want the answer, then press Insert."))
            interaction.setActions()
            overlay.showNearCursor()
            return
        }
        let appName = target.localizedName ?? "your app"
        if composer.isVisible { composer.hide() }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate(options: [])
        }
        interaction.transition(to: .working("Typing into \(appName)…"))
        interaction.setActions()
        overlay.showNearCursor()
        // Treat the delayed handoff as cancellable context work too. Escape,
        // a new question or an account switch must never type a stale answer.
        let preparation = beginContextPreparation()
        let edit = pendingEdit
        let request = pendingWriteRequest
        pendingEdit = nil
        contextPreparationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, self.isCurrentContextPreparation(preparation) else { return }
            defer { if self.contextPreparationID == preparation { self.contextPreparationTask = nil } }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                self.interaction.transition(to: .answer(answer))
                self.interaction.setActions()
                self.overlay.showNearCursor()
                return
            }
            // Replacing earlier writing: select the old text first, so the
            // paste swaps it out. (A highlight is replaced as it is.)
            // Browsers like Chrome and Brave hide page text from Accessibility
            // until asked; asking now means a later "rewrite it" can find it.
            FocusedTextInserter.enableFullAccessibility(for: target)
            var replaced = edit != nil && edit?.original == nil
            if let original = edit?.original {
                replaced = await self.textInserter.selectTextAllowingAccessibilityWarmUp(original)
                guard self.isCurrentContextPreparation(preparation),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
                guard replaced else {
                    // Never stack a second version under the old one: hand it
                    // over instead, so the user can paste it over the old text.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                    WorkMemory.shared.remember(answer, request: request, app: target)
                    self.interaction.transition(to: .transcript(
                        "Couldn't find the old version in \(appName), so nothing was changed. The new version is copied: select the old text and press ⌘V.",
                        isFinal: true))
                    self.overlay.showNearCursor()
                    self.scheduleDismissal(afterNanoseconds: 7_000_000_000)
                    return
                }
            }
            do {
                try self.textInserter.paste(answer)
                WorkMemory.shared.remember(answer, request: request, app: target)
                let message: String
                if replaced {
                    message = "Replaced in \(appName) · ⌘Z to undo"
                } else {
                    message = "Typed into \(appName)"
                }
                self.interaction.transition(to: .transcript(message, isFinal: true))
                self.overlay.showNearCursor()
                self.scheduleDismissal()
            } catch {
                self.interaction.transition(to: .answer(answer))
                self.interaction.setActions()
                self.overlay.showNearCursor()
            }
        }
    }

    @objc private func configureVocabulary() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = SpeechVocabularyStore().terms.joined(separator: "\n")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.messageText = "Technical vocabulary"
        alert.informativeText = "Add one name, code symbol, product term, or Hinglish phrase per line. Up to 100 terms are kept locally and applied to the next voice turn."
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let terms = SpeechVocabularyStore().save(text: textView.string)
        interaction.transition(to: .transcript(
            "Saved \(terms.count) vocabulary term\(terms.count == 1 ? "" : "s") • active on the next voice turn",
            isFinal: true
        ))
        overlay.showNearCursor()
        scheduleDismissal(afterNanoseconds: 4_000_000_000)
    }

    private func voiceMenuItem() -> NSMenuItem {
        let voiceMenu = NSMenu()
        let header = NSMenuItem(title: "English voice", action: nil, keyEquivalent: "")
        header.isEnabled = false
        voiceMenu.addItem(header)
        for voice in OpenRouterSpeech.englishVoices {
            let item = NSMenuItem(title: voice.name, action: #selector(selectVoice(_:)), keyEquivalent: "")
            item.representedObject = voice.id
            item.state = OpenRouterSpeech.englishVoice == voice.id ? .on : .off
            item.indentationLevel = 1
            item.target = self
            voiceMenu.addItem(item)
        }
        voiceMenu.addItem(.separator())
        let testItem = NSMenuItem(title: "Test Voice", action: #selector(testVoice), keyEquivalent: "")
        testItem.target = self
        voiceMenu.addItem(testItem)
        let root = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        root.submenu = voiceMenu
        return root
    }

    /// Speaks one line and shows exactly what happened, so a voice problem
    /// (missing key, no credit, network) is never silent.
    @objc private func testVoice() {
        interaction.transition(to: .working("Testing voice…"))
        interaction.setActions()
        overlay.showNearCursor()
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.voiceReply.test() {
            case .success:
                self.interaction.transition(to: .answer("Voice works. Answers to spoken questions will be read aloud."))
                self.interaction.setActions()
                self.overlay.showNearCursor()
                self.scheduleDismissal(afterNanoseconds: 4_000_000_000)
            case .failure(let error) where VoiceReplyController.isCancellation(error):
                // Stopped by a newer clip (for example a voice card): not an error.
                self.overlay.hide()
            case .failure(let error):
                self.interaction.transition(to: .failed(error.localizedDescription))
                self.interaction.setActions()
                self.overlay.showNearCursor()
            }
        }
    }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        OpenRouterSpeech.englishVoice = id
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .failure(let error) = await self.voiceReply.speakAndWait("Hi, I'm Bibbles. This is how I'll sound from now on."),
               !VoiceReplyController.isCancellation(error) {
                self.interaction.transition(to: .failed(error.localizedDescription))
                self.interaction.setActions()
                self.overlay.showNearCursor()
            }
        }
    }

    @objc private func selectModelPreference(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preference = ClaudeAPI.ModelPreference(rawValue: raw) else { return }
        ClaudeAPI.preference = preference
        interaction.transition(to: .transcript("AI model: \(preference.title)", isFinal: true))
        overlay.showNearCursor()
        scheduleDismissal()
    }

    @objc private func selectDictationMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DictationOutputMode(rawValue: raw) else { return }
        dictationPreferences.mode = mode
        interaction.transition(to: .transcript("Dictation mode: \(mode.title)", isFinal: true))
        overlay.showNearCursor()
        scheduleDismissal()
    }

    @objc private func teachCorrection() {
        let heard = NSTextField(frame: NSRect(x: 0, y: 34, width: 380, height: 24))
        heard.placeholderString = "Bibbles heard…"
        let replacement = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        replacement.placeholderString = "Always replace with…"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 58))
        container.addSubview(heard)
        container.addSubview(replacement)

        let alert = NSAlert()
        alert.messageText = "Approve a speech correction"
        alert.informativeText = "Bibbles will only learn this replacement after you approve it. It is stored locally and can affect future dictation."
        alert.accessoryView = container
        alert.addButton(withTitle: "Approve Correction")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let corrections = correctionStore.approve(heard: heard.stringValue, replacement: replacement.stringValue)
        interaction.transition(to: .transcript("Approved • \(corrections.count) learned correction\(corrections.count == 1 ? "" : "s")", isFinal: true))
        overlay.showNearCursor()
        scheduleDismissal(afterNanoseconds: 4_000_000_000)
    }

    @objc private func reportDictationCorrection() {
        let heard = NSTextField(frame: NSRect(x: 0, y: 34, width: 380, height: 24))
        heard.placeholderString = "Bibbles heard this term…"
        let intended = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        intended.placeholderString = "I corrected it to…"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 58))
        container.addSubview(heard)
        container.addSubview(intended)

        let alert = NSAlert()
        alert.messageText = "Report a dictation correction"
        alert.informativeText = "Bibbles stores only this term pair locally. It suggests a vocabulary entry after the same correction is reported three times; nothing is added automatically."
        alert.accessoryView = container
        alert.addButton(withTitle: "Report")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let result = correctionObservations.record(
            heard: heard.stringValue,
            intended: intended.stringValue
        ) else {
            interaction.transition(to: .failed("Enter two different terms, each at most 80 characters."))
            overlay.showNearCursor()
            return
        }

        if let suggestedTerm = result.suggestedTerm {
            let suggestion = NSAlert()
            suggestion.messageText = "Add ‘\(suggestedTerm)’ to technical vocabulary?"
            suggestion.informativeText = "You reported the same correction three times. Add the intended term to your local vocabulary? The current Worker transcription route does not accept keyterms, so this will not change cloud recognition yet."
            suggestion.addButton(withTitle: "Add to Vocabulary")
            suggestion.addButton(withTitle: "Not Now")
            if suggestion.runModal() == .alertFirstButtonReturn {
                if SpeechVocabularyStore().add(suggestedTerm) {
                    interaction.transition(to: .transcript("‘\(suggestedTerm)’ is in technical vocabulary", isFinal: true))
                } else {
                    interaction.transition(to: .failed("Technical vocabulary is full. Remove an unused term before adding ‘\(suggestedTerm)’."))
                }
            } else {
                interaction.transition(to: .transcript("Correction noted locally; vocabulary unchanged", isFinal: true))
            }
        } else {
            interaction.transition(to: .transcript(
                "Correction noted locally (\(min(result.count, 3))/3 reports before a vocabulary suggestion)",
                isFinal: true
            ))
        }
        overlay.showNearCursor()
        scheduleDismissal(afterNanoseconds: 4_000_000_000)
    }

    #if BIBBLES_DEVELOPER
    @objc private func testScreenCapture() {
        if !PermissionService.requestScreenRecording() {
            interaction.transition(to: .failed(
                ScreenCaptureServiceError.permissionRequired.localizedDescription
            ))
            overlay.showNearCursor()
            return
        }

        interaction.transition(to: .working("Capturing cursor region…"))
        overlay.showNearCursor()
        Task {
            do {
                let capture = try await screenCapture.captureCursorCrop()
                let observations = try await ocr.recognizeText(in: capture.image)
                interaction.transition(to: .transcript(
                    "Captured \(capture.image.width)×\(capture.image.height) • \(observations.count) text regions",
                    isFinal: true
                ))
                overlay.showNearCursor()
                scheduleDismissal(afterNanoseconds: 4_000_000_000)
            } catch {
                interaction.transition(to: .failed(error.localizedDescription))
                overlay.showNearCursor()
                scheduleDismissal(afterNanoseconds: 4_000_000_000)
            }
        }
    }

    @objc private func testVisionGrounding() {
        guard ClaudeAPI.apiKey(fallback: configuration.anthropicAPIKey)?.isEmpty == false else {
            interaction.transition(to: .failed("Please sign in to Bibbles first."))
            overlay.showNearCursor()
            scheduleDismissal(afterNanoseconds: 4_000_000_000)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Test screen grounding?"
        alert.informativeText = "Bibbles will send one temporary cursor-area screenshot and local OCR text through the authenticated Bibbles Worker. The image is not saved locally."
        alert.addButton(withTitle: "Run Test")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        understandScreen(question: "Identify and explain the most relevant visible UI target near the cursor.")
    }
    #endif

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
