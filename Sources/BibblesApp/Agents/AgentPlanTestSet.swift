#if BIBBLES_DEVELOPER
import Foundation

/// Developer test set for the agent planner: 30 Files requests in EN, ES, DE,
/// FR, PT, JA and Hindi/Hinglish, planned against one fake folder summary.
/// Planning only: no folder is scanned and no file is touched.
struct AgentPlanTestCase {
    let language: String
    let text: String
    /// Whether a plan does what the request asked.
    let isCorrect: (AgentRulePlan) -> Bool
}

enum AgentPlanTestSet {
    /// A typical Downloads folder (what `FolderSummarizer` would send).
    static let fakeSummary = """
    Folder: Downloads (top level)
    Items: 214 (3 folders)
    By extension: png: 61, pdf: 42, jpg: 20, zip: 15, dmg: 12, docx: 8, mov: 5, xlsx: 4, pkg: 3, csv: 2, (none): 3
    By kind: image: 81, pdf: 42, archive: 15, disk_image: 15, document: 8, video: 5, spreadsheet: 4, text: 2, folder: 3
    Name patterns (first word, 3 or more items): Screenshot: 48, IMG_: 14, Invoice: 9, Untitled: 4
    Added: 2024-03-02 to 2026-10-27; by age: over a year: 70, 1-6 months: 61, this month: 44, 6-12 months: 27, this week: 12
    Sizes: under 1 MB: 120, 1-100 MB: 78, 100 MB-1 GB: 14, over 1 GB: 2
    Existing folders: Old stuff, Projects, Receipts
    Example names:
    - Screenshot 2026-10-21 at 09.14.03.png
    - Screenshot 2026-09-02 at 18.40.11.png
    - Invoice-2026-07.pdf
    - Lease agreement.pdf
    - Zoom.pkg
    - Xcode_16.dmg
    - Docker.dmg
    - IMG_2034.jpg
    - photos-trip.zip
    - Report draft.docx
    - Budget 2026.xlsx
    - Screen Recording 2026-08-01.mov
    """

    // MARK: Checks

    static func moves(_ plan: AgentRulePlan) -> [AgentStep] { plan.steps.filter { $0.action == .move } }

    static func noTrash(_ plan: AgentRulePlan) -> Bool { !plan.steps.contains { $0.action == .trash } }

    static func movesPDFs(_ plan: AgentRulePlan, into folder: String) -> Bool {
        moves(plan).contains { step in
            (step.match.ext.contains("pdf") || step.match.kind.contains("pdf"))
                && (step.to ?? "").lowercased().contains(folder.lowercased())
        }
    }

    static func screenshotsByMonth(_ plan: AgentRulePlan) -> Bool {
        moves(plan).contains { step in
            let names = [step.match.nameStarts, step.match.nameContains].compactMap { $0?.lowercased() }
            let picksScreenshots = names.contains { $0.contains("screenshot") } || step.match.ext.contains("png")
                || step.match.kind.contains("image")
            return picksScreenshots && (step.to ?? "").contains("{month}")
        }
    }

    static func trashesInstallers(_ plan: AgentRulePlan, needsAge: Bool = false) -> Bool {
        plan.steps.contains { step in
            step.action == .trash
                && (step.match.ext.contains("dmg") || step.match.kind.contains("disk_image"))
                && (!needsAge || step.match.olderThanDays != nil)
        }
    }

    /// "Clean up / organise": moves files, deletes nothing.
    static func organises(_ plan: AgentRulePlan, minimumMoves: Int = 1) -> Bool {
        moves(plan).count >= minimumMoves && noTrash(plan)
    }

    // MARK: Cases

    static let cases: [AgentPlanTestCase] = [
        // English
        .init(language: "English", text: "Clean up my Downloads folder", isCorrect: { organises($0) }),
        .init(language: "English", text: "Put all PDFs in Downloads into a folder called Documents 2026",
              isCorrect: { movesPDFs($0, into: "Documents 2026") && noTrash($0) }),
        .init(language: "English", text: "Organize my screenshots in Downloads by month", isCorrect: { screenshotsByMonth($0) && noTrash($0) }),
        .init(language: "English", text: "Move old .dmg installers in Downloads to the Trash", isCorrect: { trashesInstallers($0, needsAge: true) }),
        .init(language: "English", text: "Put all the zip files in my Downloads into an Archives folder", isCorrect: { plan in
            moves(plan).contains { $0.match.ext.contains("zip") && ($0.to ?? "").lowercased().contains("archive") } && noTrash(plan)
        }),
        .init(language: "English", text: "Sort everything in my Downloads into folders by type", isCorrect: { organises($0, minimumMoves: 2) }),
        .init(language: "English", text: "Move all the videos in Downloads into a Videos folder", isCorrect: { plan in
            moves(plan).contains { ($0.match.kind.contains("video") || $0.match.ext.contains("mov")) && ($0.to ?? "").lowercased().contains("video") }
        }),
        .init(language: "English", text: "Get rid of installers in Downloads older than 3 months", isCorrect: { plan in
            plan.steps.contains { $0.action == .trash && ($0.match.ext.contains("dmg") || $0.match.kind.contains("disk_image"))
                && ($0.match.olderThanDays ?? 0) >= 60 }
        }),
        // Spanish
        .init(language: "Spanish", text: "Limpia mi carpeta de descargas", isCorrect: { organises($0) }),
        .init(language: "Spanish", text: "Pon todos los PDF de descargas en una carpeta llamada Facturas",
              isCorrect: { movesPDFs($0, into: "Facturas") && noTrash($0) }),
        .init(language: "Spanish", text: "Organiza mis capturas de pantalla de descargas por mes", isCorrect: { screenshotsByMonth($0) }),
        .init(language: "Spanish", text: "Mueve a la papelera los instaladores dmg antiguos de descargas", isCorrect: { trashesInstallers($0) }),
        // German
        .init(language: "German", text: "Räum meinen Download-Ordner auf", isCorrect: { organises($0) }),
        .init(language: "German", text: "Verschiebe alle PDFs aus Downloads in einen Ordner namens Rechnungen",
              isCorrect: { movesPDFs($0, into: "Rechnungen") && noTrash($0) }),
        .init(language: "German", text: "Sortiere meine Bildschirmfotos in Downloads nach Monat", isCorrect: { screenshotsByMonth($0) }),
        .init(language: "German", text: "Lösch die alten DMG-Dateien in Downloads", isCorrect: { trashesInstallers($0) }),
        // French
        .init(language: "French", text: "Range mon dossier Téléchargements", isCorrect: { organises($0) }),
        .init(language: "French", text: "Mets tous les PDF des téléchargements dans un dossier Factures",
              isCorrect: { movesPDFs($0, into: "Factures") && noTrash($0) }),
        .init(language: "French", text: "Trie mes captures d'écran des téléchargements par mois", isCorrect: { screenshotsByMonth($0) }),
        .init(language: "French", text: "Mets les vieux installateurs .dmg des téléchargements à la corbeille", isCorrect: { trashesInstallers($0) }),
        // Portuguese
        .init(language: "Portuguese", text: "Organiza a minha pasta de downloads", isCorrect: { organises($0) }),
        .init(language: "Portuguese", text: "Coloca todos os PDFs dos downloads numa pasta chamada Recibos",
              isCorrect: { movesPDFs($0, into: "Recibos") && noTrash($0) }),
        .init(language: "Portuguese", text: "Move os instaladores dmg antigos dos downloads para o Lixo", isCorrect: { trashesInstallers($0) }),
        // Japanese
        .init(language: "Japanese", text: "ダウンロードフォルダを整理して", isCorrect: { organises($0) }),
        .init(language: "Japanese", text: "ダウンロードのPDFを全部「請求書」フォルダに移動して", isCorrect: { movesPDFs($0, into: "請求書") && noTrash($0) }),
        .init(language: "Japanese", text: "ダウンロードのスクリーンショットを月ごとに整理して", isCorrect: { screenshotsByMonth($0) }),
        // Hindi / Hinglish
        .init(language: "Hinglish", text: "Downloads folder saaf kar do", isCorrect: { organises($0) }),
        .init(language: "Hinglish", text: "Downloads ki saari PDF files ko Bills naam ke folder mein daal do",
              isCorrect: { movesPDFs($0, into: "Bills") && noTrash($0) }),
        .init(language: "Hinglish", text: "Downloads ke purane dmg installers trash mein daal do", isCorrect: { trashesInstallers($0) }),
        .init(language: "Hindi", text: "डाउनलोड फ़ोल्डर को फ़ाइल के प्रकार के हिसाब से व्यवस्थित कर दो", isCorrect: { organises($0, minimumMoves: 2) })
    ]
}

/// One planner answer in the test set.
struct AgentPlanTestRow {
    let model: ModelChoice
    let index: Int
    let language: String
    let validJSON: Bool
    /// Every step used an allowed action.
    let allowedActions: Bool
    let correct: Bool
    let milliseconds: Int
    let cost: Double?
    let failure: String?
}

enum AgentPlanTestRunner {
    /// Long enough to measure slow planners (the live limit is 5 s, then the backup).
    static let measurementTimeout: TimeInterval = 20

    /// The planner models that have a saved key.
    static var availableModels: [ModelChoice] {
        ModelCatalog.choices(for: .agentPlanner).filter { DeveloperKeychain.has($0.provider.keySlot) }
    }

    static func run(models: [ModelChoice], cases: [AgentPlanTestCase] = AgentPlanTestSet.cases, concurrency: Int = 3,
                    session: URLSession = .shared, progress: @escaping @Sendable (Int, Int) async -> Void) async -> [AgentPlanTestRow] {
        let jobs = models.flatMap { model in cases.indices.map { (model, $0) } }
        var rows: [AgentPlanTestRow] = []
        await withTaskGroup(of: AgentPlanTestRow.self) { group in
            var next = 0
            func add() {
                let (model, index) = jobs[next]
                let item = cases[index]
                group.addTask { await row(model: model, item: item, index: index, session: session) }
                next += 1
            }
            while next < min(concurrency, jobs.count) { add() }
            while let finished = await group.next() {
                rows.append(finished)
                await progress(rows.count, jobs.count)
                if next < jobs.count { add() }
            }
        }
        return rows.sorted { ($0.model.id, $0.index) < ($1.model.id, $1.index) }
    }

    static func row(model: ModelChoice, item: AgentPlanTestCase, index: Int, session: URLSession) async -> AgentPlanTestRow {
        let system = FilesAgentPrompt.system(replyLanguage: ToolGate.replyLanguageRule)
        let user = FilesAgentPrompt.user(request: item.text, summary: AgentPlanTestSet.fakeSummary)
        let started = Date()
        do {
            let reply = try await AgentPlanner.withTimeout(measurementTimeout) {
                try await AgentPlanner.ask(model: model, system: system, user: user, backup: false, session: session)
            }
            let parsed = AgentPlanParser.parse(reply.text)
            let allowed = parsed.isValid && !parsed.dropped.contains { $0.reason.contains("is not allowed") }
            return AgentPlanTestRow(model: model, index: index, language: item.language, validJSON: parsed.isValid,
                                    allowedActions: allowed, correct: parsed.plan.map(item.isCorrect) ?? false,
                                    milliseconds: reply.milliseconds, cost: reply.estimatedCost, failure: parsed.error)
        } catch {
            let failure = (error as? LocalBackendError)?.localizedDescription
                ?? (error is AgentPlanner.PlannerTimeout ? "timeout" : "network")
            return AgentPlanTestRow(model: model, index: index, language: item.language, validJSON: false, allowedActions: false,
                                    correct: false, milliseconds: Int(Date().timeIntervalSince(started) * 1000), cost: nil,
                                    failure: failure)
        }
    }

    /// A Markdown report: per model valid JSON %, allowed actions %, correct
    /// plan %, average and slowest ms, estimated cost per plan; then each row.
    static func report(_ rows: [AgentPlanTestRow], date: Date = Date()) -> String {
        func percent(_ part: Int, _ total: Int) -> String { total == 0 ? "—" : String(format: "%.0f%%", Double(part) * 100 / Double(total)) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["# Agent plan test set", "", "\(formatter.string(from: date)) · \(AgentPlanTestSet.cases.count) requests per model · planning only, no files touched", "",
                     "| Model | Valid JSON | Allowed actions | Correct plan | Avg ms | Slowest ms | Est. cost / plan |",
                     "|---|---|---|---|---|---|---|"]
        let models = rows.map(\.model).reduce(into: [ModelChoice]()) { if !$0.contains($1) { $0.append($1) } }
        for model in models {
            let mine = rows.filter { $0.model == model }
            let times = mine.map(\.milliseconds)
            let costs = mine.compactMap(\.cost)
            lines.append("| \(model.name) (\(model.id)) | \(percent(mine.filter(\.validJSON).count, mine.count)) | "
                         + "\(percent(mine.filter(\.allowedActions).count, mine.count)) | \(percent(mine.filter(\.correct).count, mine.count)) | "
                         + "\(times.isEmpty ? 0 : times.reduce(0, +) / times.count) | \(times.max() ?? 0) | "
                         + "\(costs.isEmpty ? "—" : ModelCatalog.formatted(costs.reduce(0, +) / Double(costs.count))) |")
        }
        lines += ["", "| Model | # | Language | Valid | Allowed | Correct | ms | Problem |", "|---|---|---|---|---|---|---|---|"]
        for row in rows {
            lines.append("| \(row.model.name) | \(row.index + 1) | \(row.language) | \(row.validJSON ? "yes" : "no") | "
                         + "\(row.allowedActions ? "yes" : "no") | \(row.correct ? "yes" : "no") | \(row.milliseconds) | \(row.failure ?? "") |")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
