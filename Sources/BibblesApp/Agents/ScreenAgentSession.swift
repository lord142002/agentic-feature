#if BIBBLES_DEVELOPER
import AppKit
import Foundation

/// One Screen agent run: read the app (Accessibility, text only) → plan
/// (on the Mac for "fill with my details", otherwise one AI call) → check
/// every step → preview → Start → run (Stop) → Done · Undo for typed fields
/// and dark mode.
@MainActor
final class ScreenAgentSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case looking, planning, preview
        case running(done: Int, total: Int)
        case stopping, done, undoing, undone
        case failed(String)
    }

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

    private var executor: ScreenExecutor?
    private var result: ScreenRunResult?
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
        if case let .running(done, total) = phase { return "Step \(done) of \(total)…" }
        return ""
    }

    func start() {
        work?.cancel()
        phase = .looking
        log = AgentLogEntry(route: "agent_screen", layer: layer)
        let text = request.text
        work = Task { [weak self] in
            guard let self else { return }
            do {
                guard AXIsProcessTrusted() else {
                    throw AgentError.permission("Bibbles needs Accessibility: System Settings → Privacy & Security → Accessibility → Bibbles Dev.")
                }
                guard let app = self.app, !app.isTerminated else {
                    throw AgentError.folder("Click into the app you want Bibbles to work in, then ask again.")
                }
                let snapshot = ScreenAX.snapshot(of: app)
                let details = MyDetailsStore.load()
                self.log.filesScanned = snapshot.fields.count + snapshot.controls.count
                let plan: ScreenPlan
                var dropped: [AgentDroppedStep] = []
                if ScreenAgentDetector.isDetailsFill(text) {
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
                    self.phase = .planning
                    let started = Date()
                    let models = [ModelCatalog.selected(.screenAgent), ModelCatalog.selected(.agentBackup)]
                    let (reply, parsed) = try await AgentPlanner.planned(
                        system: ScreenAgentPrompt.system(replyLanguage: ToolGate.replyLanguageRule),
                        user: ScreenAgentPrompt.user(request: text, snapshot: snapshot.describe(details: details)),
                        models: models, schema: ScreenPlanParser.schema, schemaName: "screen_plan",
                        session: .shared) { raw -> ScreenParseResult? in
                        let candidate = ScreenPlanParser.parse(raw)
                        return candidate.isValid ? candidate : nil
                    }
                    try Task.checkCancellation()
                    guard let parsedPlan = parsed.plan else { throw AgentError.planFailed("invalid plan") }
                    plan = parsedPlan
                    dropped = parsed.dropped
                    self.log.planMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
                    self.log.plannerModel = reply.model.id + (reply.usedBackup ? " (backup)" : "")
                    self.log.estimatedCost = reply.estimatedCost
                }
                let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot, request: text, details: details, dropped: dropped)
                self.log.stepsPlanned = plan.steps.count + dropped.count
                self.log.stepsDropped = preview.dropped.count
                self.log.stepsValid = preview.actions.count
                self.planSummary = plan.summary
                self.preview = preview
                self.phase = .preview
            } catch is CancellationError {
                return
            } catch {
                self.phase = .failed(error.localizedDescription)
                AgentLog.shared.record(self.log)
            }
        }
    }

    /// Start: the only way anything happens on screen.
    func confirm() {
        guard phase == .preview, !preview.isEmpty, let app else { return }
        let executor = ScreenExecutor(inserter: inserter)
        self.executor = executor
        let actions = preview.actions
        phase = .running(done: 0, total: actions.count)
        let started = Date()
        work = Task { [weak self] in
            let result = await executor.run(actions, in: app) { done, total in
                self?.phase = .running(done: done, total: total)
            }
            self?.finish(result, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
        }
    }

    func stop() {
        guard case .running = phase else { return }
        executor?.stop()
        phase = .stopping
    }

    private func finish(_ result: ScreenRunResult, milliseconds: Int) {
        self.result = result
        finishedAt = Date()
        var sentences: [String] = []
        savedFile = result.savedFile
        if let file = result.savedFile {
            sentences.append("Saved \(file.lastPathComponent) in \(ScreenSaveLocation.display(file.deletingLastPathComponent())).")
        }
        if result.filled > 0 { sentences.append("Filled \(result.filled) field\(result.filled == 1 ? "" : "s").") }
        let other = result.done - result.filled - result.failed
        if other > 0 { sentences.append("Did \(other) step\(other == 1 ? "" : "s").") }
        if let problem = result.firstError { sentences.append("Stopped: \(problem).") }
        else if result.stopped { sentences.append(strings.stopped(result.done, result.total)) }
        if preview.dropped.contains(where: { $0.reason.hasPrefix("Bibbles never presses") }) {
            sentences.append("Check everything, then press the final button yourself.")
        }
        resultSummary = sentences.isEmpty ? strings.nothing : sentences.joined(separator: " ")
        canUndo = !result.previousValues.isEmpty || result.darkModeBefore != nil
        phase = .done
        log.executeMilliseconds = milliseconds
        log.stopped = result.stopped
        AgentLog.shared.record(log)
        onFinished?(resultSummary)
    }

    var undoAvailable: Bool {
        guard canUndo, let finishedAt else { return false }
        return Date().timeIntervalSince(finishedAt) < UndoLog.lifetime
    }

    /// Puts typed fields back as they were, and dark mode.
    func undo() {
        guard undoAvailable, let result, let executor, let app else { canUndo = false; return }
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
