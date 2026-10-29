#if BIBBLES_DEVELOPER
import Foundation

/// One Files agent run: scan → summarize → plan (the one AI call) → apply +
/// validate → preview → Start → execute (Stop) → Done · Undo → summary.
/// Nothing changes on disk before the user presses Start.
@MainActor
final class FilesAgentSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case scanning
        case planning
        case preview
        case running(done: Int, total: Int)
        case stopping
        case done
        case undoing
        case undone
        case failed(String)
    }

    let id = UUID()
    let request: AgentRequest
    let strings: FilesAgentStrings
    /// Where the request was recognised (developer log): "keyword" or "router".
    let layer: String

    @Published private(set) var phase: Phase = .scanning
    @Published private(set) var preview = FilesAgentPreview()
    /// The planner's one-sentence description, in the user's language.
    @Published private(set) var planSummary = ""
    @Published private(set) var resultSummary = ""
    @Published private(set) var canUndo = false

    private(set) var result: AgentResult?
    private var scan: FolderScan?
    private var executor: AgentExecutor?
    private var work: Task<Void, Never>?
    private var log = AgentLogEntry()

    /// After a finished run: the summary (for chat history and voice).
    var onFinished: ((String) -> Void)?
    var onUndone: ((String) -> Void)?

    init(text: String, layer: String = "keyword") {
        request = AgentRequest(text: text)
        strings = FilesAgentStrings.forRequest(text)
        self.layer = layer
    }

    var progressText: String {
        if case let .running(done, total) = phase { return strings.moving(done, total) }
        return ""
    }

    // MARK: Plan and preview

    func start() {
        work?.cancel()
        phase = .scanning
        log = AgentLogEntry(layer: layer)
        let text = request.text
        work = Task { [weak self] in
            guard let self else { return }
            do {
                guard LocalMode.isOn else { throw AgentError.needsLocalMode }
                guard let target = FilesAgentDetector.target(in: text), let root = target.url else {
                    throw AgentError.folder("Say which folder to organise: Downloads, Desktop or Documents.")
                }
                let recursive = FilesAgentDetector.wantsSubfolders(text)
                let scan: FolderScan
                do {
                    scan = try await Task.detached(priority: .userInitiated) {
                        try FolderScanner.scan(root, recursive: recursive)
                    }.value
                } catch let error as AgentError {
                    throw error
                } catch {
                    throw AgentExecutor.isPermission(error) ? AgentError.permission(target.permissionMessage)
                        : AgentError.folder("Bibbles couldn't read your \(target.displayName) folder.")
                }
                try Task.checkCancellation()
                self.scan = scan
                self.log.filesScanned = scan.items.count
                self.phase = .planning
                let summary = FolderSummarizer.summarize(scan, folderName: target.displayName)
                let planStarted = Date()
                let attempt = try await AgentPlanner.plan(system: FilesAgentPrompt.system(replyLanguage: ToolGate.replyLanguageRule),
                                                          user: FilesAgentPrompt.user(request: text, summary: summary))
                try Task.checkCancellation()
                self.log.planMilliseconds = Int(Date().timeIntervalSince(planStarted) * 1000)
                self.log.plannerModel = attempt.reply.model.id + (attempt.reply.usedBackup ? " (backup)" : "")
                self.log.estimatedCost = attempt.reply.estimatedCost
                guard let plan = attempt.parsed.plan else { throw AgentError.planFailed("invalid plan") }
                let dropped = attempt.parsed.dropped
                let preview = await Task.detached(priority: .userInitiated) {
                    FilesPlanApplier.apply(plan, to: scan, dropped: dropped)
                }.value
                try Task.checkCancellation()
                guard preview.fileCount <= FilesPlanApplier.maxFiles else {
                    throw AgentError.tooBig("That would change more than \(FilesPlanApplier.maxFiles) files. Ask for one kind of file or one folder at a time.")
                }
                self.log.stepsPlanned = plan.steps.count + dropped.count
                self.log.stepsDropped = preview.dropped.count
                self.log.stepsValid = max(0, self.log.stepsPlanned - self.log.stepsDropped)
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

    // MARK: Execute

    /// Start: the only way anything changes on disk.
    func confirm() {
        guard phase == .preview, !preview.isEmpty else { return }
        let executor = AgentExecutor()
        self.executor = executor
        let operations = preview.operations
        phase = .running(done: 0, total: operations.count)
        work = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                executor.run(operations) { done, total, _ in
                    Task { @MainActor [weak self] in self?.progressChanged(done, total) }
                }
            }.value
            self?.finish(result)
        }
    }

    private func progressChanged(_ done: Int, _ total: Int) {
        guard case .running(let shown, _) = phase, done > shown else { return }
        phase = .running(done: done, total: total)
    }

    /// Stop: the current file finishes, then it halts cleanly.
    func stop() {
        guard case .running = phase else { return }
        executor?.stop()
        phase = .stopping
    }

    private func finish(_ result: AgentResult) {
        self.result = result
        var summary = strings.summary(result)
        if let problem = result.firstError, problem == "permission", let target = FilesAgentDetector.target(in: request.text) {
            summary += " " + target.permissionMessage
        }
        resultSummary = summary
        canUndo = result.undo.isAvailable()
        phase = .done
        log.executeMilliseconds = result.milliseconds
        log.stopped = result.stopped || result.timedOut
        AgentLog.shared.record(log)
        if canUndo { AgentUndoRegistry.shared.register(self, answer: summary) }
        onFinished?(summary)
    }

    // MARK: Undo

    /// Undo stays available for 30 minutes (here and in task history).
    var undoAvailable: Bool { canUndo && (result?.undo.isAvailable() ?? false) }

    func undo() {
        guard undoAvailable, let undoLog = result?.undo else { canUndo = false; return }
        phase = .undoing
        canUndo = false
        let entryDate = log.date
        work = Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) { AgentExecutor.undo(undoLog) }.value
            guard let self else { return }
            self.phase = .undone
            AgentUndoRegistry.shared.remove(self)
            AgentLog.shared.markUndone(at: entryDate)
            self.onUndone?(self.strings.undone)
        }
    }

    /// Cancel before Start: nothing has changed.
    func cancel() {
        work?.cancel()
        executor?.stop()
    }
}

/// Finished runs that can still be undone (30 minutes), so task history can
/// offer Undo too. Only summaries are keys: never file names.
@MainActor
final class AgentUndoRegistry {
    static let shared = AgentUndoRegistry()
    private var sessions: [(answer: String, session: FilesAgentSession)] = []

    func register(_ session: FilesAgentSession, answer: String) {
        prune()
        sessions.removeAll { $0.session === session }
        sessions.append((answer.trimmingCharacters(in: .whitespacesAndNewlines), session))
    }

    func remove(_ session: FilesAgentSession) {
        sessions.removeAll { $0.session === session }
    }

    /// The run whose summary is this task history answer, while Undo is still possible.
    func session(forAnswer answer: String) -> FilesAgentSession? {
        prune()
        let key = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.last { $0.answer == key }?.session
    }

    var latest: FilesAgentSession? {
        prune()
        return sessions.last?.session
    }

    private func prune() {
        sessions.removeAll { !$0.session.undoAvailable }
    }
}
#endif
