#if BIBBLES_DEVELOPER
import AppKit
import Foundation

/// One Screen agent run, in rounds: look (Accessibility text + a screenshot)
/// → plan (one AI call; "fill … with my details" is planned on the Mac with
/// no AI) → check every step → preview → Start → run (Stop) → look again
/// while the planner says more is needed (up to 8 rounds, 10 minutes).
/// Rounds that type text or contain a final action wait for Continue; final
/// actions (Send, Buy…) also ask right before they happen.
@MainActor
final class ScreenAgentSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case looking, planning, preview
        case running(done: Int, total: Int)
        case stopping, done, undoing, undone
        case failed(String)
    }

    static let maxRounds = 8
    static let maxDuration: TimeInterval = 10 * 60

    let id = UUID()
    let request: AgentRequest
    let strings: FilesAgentStrings
    let layer: String
    let app: NSRunningApplication?
    private let inserter: FocusedTextInserter

    @Published private(set) var phase: Phase = .looking
    @Published private(set) var preview = ScreenPreview()
    @Published private(set) var planSummary = ""
    @Published private(set) var resultSummary = ""
    @Published private(set) var canUndo = false
    /// True when the plan was made on the Mac with no AI call.
    @Published private(set) var madeOnMac = false
    /// The file a save or export wrote (Show in Finder).
    @Published private(set) var savedFile: URL?
    /// 1 for the first plan; more when Bibbles looked again.
    @Published private(set) var round = 1
    /// What was done so far, one line per step.
    @Published private(set) var history: [String] = []

    private var executor: ScreenExecutor?
    private var result = ScreenRunResult()
    private var planDone = true
    private var startedAt = Date()
    private var finishedAt: Date?
    private var work: Task<Void, Never>?
    private var log = AgentLogEntry(route: "agent_screen")

    var onFinished: ((String) -> Void)?

    init(text: String, app: NSRunningApplication?, inserter: FocusedTextInserter, layer: String = "keyword") {
        request = AgentRequest(text: text)
        strings = FilesAgentStrings.forRequest(text)
        self.app = app
        self.inserter = inserter
        self.layer = layer
    }

    var progressText: String {
        if case let .running(done, total) = phase {
            return (round > 1 ? "Part \(round) · " : "") + "Step \(done) of \(total)…"
        }
        return ""
    }

    /// "Start" for the first plan, "Continue" for later ones.
    var startTitle: String { round == 1 ? strings.start : "Continue" }

    func start() {
        work?.cancel()
        round = 1
        history = []
        result = ScreenRunResult()
        startedAt = Date()
        log = AgentLogEntry(route: "agent_screen", layer: layer)
        planRound()
    }

    // MARK: Look and plan

    private func planRound() {
        phase = .looking
        let text = request.text
        let isFirst = round == 1
        work = Task { [weak self] in
            guard let self else { return }
            do {
                guard AXIsProcessTrusted() else {
                    throw AgentError.permission("Bibbles needs Accessibility: System Settings → Privacy & Security → Accessibility → Bibbles Dev.")
                }
                guard let app = self.app, !app.isTerminated else {
                    throw AgentError.folder("Click into the app you want Bibbles to work in, then ask again.")
                }
                var snapshot = ScreenAX.snapshot(of: app)
                let details = MyDetailsStore.load()
                self.log.filesScanned += snapshot.fields.count + snapshot.controls.count
                let plan: ScreenPlan
                var dropped: [AgentDroppedStep] = []
                if isFirst, ScreenAgentDetector.isDetailsFill(text) {
                    // Personal details: matched on the Mac, never sent to an AI.
                    guard !details.isEmpty else {
                        throw AgentError.folder("Add your details first: Settings → Developer → My details (or use your Contacts card).")
                    }
                    guard !snapshot.fields.isEmpty else {
                        throw AgentError.folder("Bibbles can't see any fields in \(snapshot.appName). Click into the form, then ask again.")
                    }
                    plan = ScreenPlanValidator.detailsPlan(fields: snapshot.fields, details: details)
                    self.madeOnMac = true
                    self.log.plannerModel = "on this Mac (no AI)"
                } else {
                    // A screenshot lets the planner click what Accessibility can't describe.
                    let capture = await Self.screenshot(of: app)
                    snapshot.screenFrame = capture?.frame
                    self.phase = .planning
                    let started = Date()
                    let models = [ModelCatalog.selected(.screenAgent), ModelCatalog.selected(.agentBackup)]
                    let (reply, parsed) = try await AgentPlanner.planned(
                        system: ScreenAgentPrompt.system(replyLanguage: ToolGate.replyLanguageRule),
                        user: ScreenAgentPrompt.user(request: text, snapshot: snapshot.describe(details: details), history: self.history),
                        models: models, schema: ScreenPlanParser.schema, schemaName: "screen_plan",
                        maxTokens: 4_000, timeLimit: 45, image: capture?.jpeg,
                        session: .shared) { raw -> ScreenParseResult? in
                        let candidate = ScreenPlanParser.parse(raw)
                        return candidate.isValid ? candidate : nil
                    }
                    try Task.checkCancellation()
                    guard let parsedPlan = parsed.plan else { throw AgentError.planFailed("invalid plan") }
                    plan = parsedPlan
                    dropped = parsed.dropped
                    self.log.planMilliseconds = (self.log.planMilliseconds ?? 0) + Int(Date().timeIntervalSince(started) * 1000)
                    self.log.plannerModel = reply.model.id + (reply.usedBackup ? " (backup)" : "")
                    self.log.estimatedCost = (self.log.estimatedCost ?? 0) + (reply.estimatedCost ?? 0)
                }
                let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot, request: text, details: details, dropped: dropped)
                self.log.stepsPlanned += plan.steps.count + dropped.count
                self.log.stepsDropped += preview.dropped.count
                self.log.stepsValid += preview.actions.count
                self.planDone = plan.done
                if !plan.summary.isEmpty { self.planSummary = plan.summary }
                self.preview = preview
                if preview.isEmpty, !isFirst {
                    self.finish()
                } else if isFirst || preview.needsApproval {
                    self.phase = .preview
                } else {
                    // Clicks, keys and waits in later rounds run straight on (Stop works).
                    self.phase = .preview
                    self.confirm()
                }
            } catch is CancellationError {
                return
            } catch {
                if isFirst {
                    self.phase = .failed(error.localizedDescription)
                    AgentLog.shared.record(self.log)
                } else {
                    self.result.firstError = self.result.firstError ?? error.localizedDescription
                    self.finish()
                }
            }
        }
    }

    /// The screen under the app's window, as JPEG, plus where that display is.
    private static func screenshot(of app: NSRunningApplication) async -> (jpeg: Data, frame: CGRect)? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let center = windowCenter(of: app) ?? NSEvent.mouseLocation
        guard let capture = try? await ScreenCaptureService().captureDisplayOverview(cursor: center, maximumLongEdgePixels: 1_600),
              let jpeg = NSBitmapImageRep(cgImage: capture.image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return nil }
        return (jpeg, capture.descriptor.displayFrameInQuartzPoints)
    }

    /// The front window's centre in AppKit coordinates (picks the display to capture).
    private static func windowCenter(of app: NSRunningApplication) -> CGPoint? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = ScreenAX.element(appElement, kAXFocusedWindowAttribute),
              let rawPosition = ScreenAX.value(window, kAXPositionAttribute), let rawSize = ScreenAX.value(window, kAXSizeAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &position)
        AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
        return CGPoint(x: position.x + size.width / 2, y: ScreenGeometry.primaryHeight - (position.y + size.height / 2))
    }

    // MARK: Run

    /// Start / Continue: the only way anything happens on screen.
    func confirm() {
        guard phase == .preview, !preview.isEmpty, let app else { return }
        let executor = self.executor ?? ScreenExecutor(inserter: inserter)
        self.executor = executor
        let actions = preview.actions
        let lines = preview.lines.map(\.text)
        phase = .running(done: 0, total: actions.count)
        let roundStarted = Date()
        work = Task { [weak self] in
            let roundResult = await executor.run(actions, in: app) { done, total in
                self?.phase = .running(done: done, total: total)
            }
            guard let self else { return }
            self.merge(roundResult)
            self.history += lines.prefix(roundResult.done)
            self.log.executeMilliseconds = (self.log.executeMilliseconds ?? 0) + Int(Date().timeIntervalSince(roundStarted) * 1000)
            let outOfTime = Date().timeIntervalSince(self.startedAt) > Self.maxDuration
            if roundResult.stopped || roundResult.firstError != nil || self.planDone || self.round >= Self.maxRounds || outOfTime {
                if !self.planDone, self.round >= Self.maxRounds || outOfTime { self.result.stopped = true }
                self.finish()
            } else {
                self.round += 1
                self.planRound()
            }
        }
    }

    private func merge(_ part: ScreenRunResult) {
        result.done += part.done
        result.total += part.total
        result.failed += part.failed
        result.filled += part.filled
        result.stopped = result.stopped || part.stopped
        result.firstError = result.firstError ?? part.firstError
        result.previousValues += part.previousValues
        result.darkModeBefore = result.darkModeBefore ?? part.darkModeBefore
        result.savedFile = part.savedFile ?? result.savedFile
    }

    func stop() {
        switch phase {
        case .running:
            executor?.stop()
            phase = .stopping
        case .looking, .planning:
            work?.cancel()
            result.stopped = true
            finish()
        default:
            break
        }
    }

    private func finish() {
        finishedAt = Date()
        var sentences: [String] = []
        savedFile = result.savedFile
        if let file = result.savedFile {
            sentences.append("Saved \(file.lastPathComponent) in \(ScreenSaveLocation.display(file.deletingLastPathComponent())).")
        }
        if result.filled > 0 { sentences.append("Filled \(result.filled) field\(result.filled == 1 ? "" : "s").") }
        let other = result.done - result.filled - result.failed
        if other > 0 { sentences.append("Did \(other) step\(other == 1 ? "" : "s")" + (round > 1 ? " in \(round) parts." : ".")) }
        if let problem = result.firstError { sentences.append("Stopped: \(problem).") }
        else if result.stopped { sentences.append(strings.stopped(result.done, result.total)) }
        resultSummary = sentences.isEmpty ? strings.nothing : sentences.joined(separator: " ")
        canUndo = !result.previousValues.isEmpty || result.darkModeBefore != nil
        phase = .done
        log.stopped = result.stopped
        AgentLog.shared.record(log)
        onFinished?(resultSummary)
    }

    var undoAvailable: Bool {
        guard canUndo, let finishedAt else { return false }
        return Date().timeIntervalSince(finishedAt) < UndoLog.lifetime
    }

    /// Puts typed fields back as they were, and dark mode. Clicks, typed
    /// text and sent messages can't be undone.
    func undo() {
        guard undoAvailable, let executor, let app else { canUndo = false; return }
        let result = self.result
        phase = .undoing
        canUndo = false
        let entryDate = log.date
        work = Task { [weak self] in
            _ = await executor.undo(result, in: app)
            guard let self else { return }
            self.phase = .undone
            AgentLog.shared.markUndone(at: entryDate)
        }
    }

    func cancel() {
        work?.cancel()
        executor?.stop()
    }
}
#endif
