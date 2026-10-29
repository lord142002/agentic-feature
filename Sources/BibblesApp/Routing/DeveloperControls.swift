import AppKit
import Foundation

/// The developer test controls shared by the Option-click Developer menu and
/// Settings → Developer, so both always show the same state. Nothing here
/// changes the available tool set. The Tool Gate and AI router are on by
/// default; experimental keyword improvements are off.
@MainActor
final class DeveloperControls: ObservableObject {
    static let shared = DeveloperControls()

    @Published private(set) var toolGate = ToolGate.isEnabled
    @Published private(set) var keywordImprovements = HybridRouter.keywordImprovementsEnabled
    @Published private(set) var aiRouter = HybridRouter.isEnabled
    @Published private(set) var hasRouterKey = false
    @Published private(set) var recordingLog = false
    @Published private(set) var logCount = 0
    @Published private(set) var testRunning = false
    @Published private(set) var testProgress: (done: Int, total: Int)?
    /// The latest result line, e.g. "Report copied · old 25/150 → …".
    @Published var message: String?
    @Published private(set) var messageIsError = false
    /// Extra progress output for the run in progress (the menu's notes).
    private var progressNote: ((String) -> Void)?

    /// Settings → Developer is shown in developer builds (bundle id ending in
    /// ".dev"), with BIBBLES_DEVELOPER=1, or after `defaults write <bundle id>
    /// bibbles.showDeveloperSettings -bool YES`.
    static var isAvailable: Bool {
        if UserDefaults.standard.object(forKey: "bibbles.showDeveloperSettings") as? Bool == false { return false }
        if UserDefaults.standard.bool(forKey: "bibbles.showDeveloperSettings") { return true }
        if ProcessInfo.processInfo.environment["BIBBLES_DEVELOPER"] == "1" { return true }
        return Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    }

    private init() {}

    /// Re-reads everything (toggles can also change from the menu).
    func refresh() {
        toolGate = ToolGate.isEnabled
        keywordImprovements = HybridRouter.keywordImprovementsEnabled
        aiRouter = HybridRouter.isEnabled
        hasRouterKey = RouterKeychain.hasKey
        recordingLog = ToolGateLog.shared.isRecording
        logCount = ToolGateLog.shared.entries.count
    }

    // MARK: Toggles

    func setToolGate(_ on: Bool) {
        ToolGate.isEnabled = on
        refresh()
    }

    func setKeywordImprovements(_ on: Bool) {
        HybridRouter.keywordImprovementsEnabled = on
        refresh()
    }

    func setAIRouter(_ on: Bool) {
        HybridRouter.isEnabled = on
        if on { RouterWarmUp.ifNeeded() }
        refresh()
    }

    func setRecordingLog(_ on: Bool) {
        ToolGateLog.shared.isRecording = on
        refresh()
    }

    /// A one-line warning when a toggle can't take effect yet (nil = fine).
    var warning: String? {
        if (aiRouter || keywordImprovements) && !toolGate { return "Turn the Tool Gate on: keyword improvements and the AI router only run with it." }

        return nil
    }

    // MARK: Router test key (Keychain only)

    @discardableResult
    func saveRouterKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ok = RouterKeychain.save(trimmed)
        show(ok ? "Router test key saved in Keychain" : "Couldn't save the key to Keychain", error: !ok)
        refresh()
        if ok { RouterWarmUp.ifNeeded() }
        return ok
    }

    func removeRouterKey() {
        RouterKeychain.delete()
        show("Router test key removed")
        refresh()
    }

    // MARK: Tool Gate log

    @discardableResult
    func copyLog() -> Bool {
        refresh()
        guard !ToolGateLog.shared.entries.isEmpty else {
            show(ToolGateStrings.logEmpty, error: true)
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ToolGateLog.shared.table(), forType: .string)
        show("\(ToolGateStrings.logCopied) (\(ToolGateLog.shared.entries.count))")
        return true
    }

    func clearLog() {
        ToolGateLog.shared.clear()
        show(ToolGateStrings.menuClearLog)
        refresh()
    }

    // MARK: Router test set

    /// Runs the test set (router only: no answers, no Worker requests) and
    /// copies the report. `onProgress` lets the menu show notes too.
    func runTestSet(onProgress: ((String) -> Void)? = nil) {
        guard !testRunning else { return }
        guard let client = RouterClient.developer() else {
            show("Add a router test key first.", error: true)
            onProgress?("Add a Router test key first (Developer → Router test key…)")
            return
        }
        testRunning = true
        progressNote = onProgress
        testProgress = (0, RouterTestSet.cases.count)
        show("Running \(RouterTestSet.cases.count) phrases…")
        onProgress?("Router test: starting \(RouterTestSet.cases.count) phrases…")
        Task { @MainActor in
            let rows = await RouterTestRunner.run(client: client) { done, total in
                await MainActor.run {
                    let controls = DeveloperControls.shared
                    controls.testProgress = (done, total)
                    if done % 10 == 0 || done == total { controls.progressNote?("Router test: \(done)/\(total)…") }
                }
            }
            self.testRunning = false
            self.testProgress = nil
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RouterTestRunner.report(rows), forType: .string)
            let total = rows.count
            let old = rows.filter { $0.today == $0.expected }.count
            let new = rows.filter { $0.newKeywords == $0.expected }.count
            let hybrid = rows.filter { $0.hybrid == $0.expected }.count
            let summary = "Report copied · old \(old)/\(total) → new keywords \(new)/\(total) → + router \(hybrid)/\(total)"
            self.show(summary)
            self.progressNote?(summary)
            self.progressNote = nil
        }
    }

    private func show(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }
}
