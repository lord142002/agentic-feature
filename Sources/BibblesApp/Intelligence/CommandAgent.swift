import AppKit
import Foundation

/// One tool call Claude asked for.
struct AgentToolCall: Equatable {
    let name: String
    let input: [String: AgentValue]

    func string(_ key: String) -> String? {
        if case let .string(value)? = input[key] { return value }
        return nil
    }

    func int(_ key: String) -> Int? {
        switch input[key] {
        case .number(let value)?:
            // Model JSON can contain 1e100; converting it with Int(value)
            // traps instead of reporting invalid tool input.
            guard value.isFinite else { return nil }
            return Int(exactly: value.rounded(.towardZero))
        case .string(let value)?: return Int(value)
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool? {
        if case let .bool(value)? = input[key] { return value }
        return nil
    }
}

enum AgentValue: Equatable {
    case string(String), number(Double), bool(Bool), other

    init(_ value: Any) {
        if let bool = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            self = .bool(bool)
        } else if let number = value as? NSNumber {
            self = .number(number.doubleValue)
        } else if let string = value as? String {
            self = .string(string)
        } else {
            self = .other
        }
    }
}

struct AgentPlan: Equatable {
    let calls: [AgentToolCall]
    let text: String
}

/// Turns spoken commands into Mac actions using Claude tool use: one fast
/// request, then Bibbles runs the chosen tools locally.
enum CommandAgent {
    static let tools: [[String: Any]] = [
        tool("music", "Control Spotify or Apple Music. Use for music playback, songs, artists, genres, pause/resume and skip. Apple Music searches the local library first, then plays catalog matches using MusicKit when access and a subscription are available. Spotify song search still requires user playback. Never use for questions, negations, quoted instructions or scheduling. Never generate AppleScript or invent track IDs.",
             ["action": prop("string", "play, pause, resume, next or previous"),
              "app": prop("string", "spotify or apple_music when the user names a player; otherwise use auto, which defaults to Apple Music"),
              "query": prop("string", "For play only: song title and artist or genre. Omit filler like some; omit for resume/current queue."),
              "kind": prop("string", "For play: song or genre. Choose genre for styles like classic rock, song for named tracks.")], required: ["action", "app"]),
        tool("lock_screen", "Lock this Mac immediately, keeping apps open. Only for an explicit user request to lock. Never for a how-to question, quoted text, negation, sleep, logout, shutdown, or a delayed/conditional request. No scheduling is supported.", [:], required: []),
        tool("open_app", "Open (launch) an installed Mac app.",
             ["name": prop("string", "App name, e.g. Spotify, Safari, System Settings")], required: ["name"]),
        tool("open_website", "Open a website in the default browser. Use a full URL; for a web search use a Google search URL.",
             ["url": prop("string", "e.g. https://www.youtube.com")], required: ["url"]),
        tool("open_folder", "Open a folder in Finder.",
             ["location": prop("string", "desktop, documents, downloads, home or applications")], required: ["location"]),
        tool("find_files", "Find files or folders on the Mac with Spotlight and show the matches.",
             ["name": prop("string", "Key words from the file name, e.g. resume. Omit filler words like my, the, file."),
              "file_type": prop("string", "any, pdf, image, video, audio, folder, word, spreadsheet, presentation or text"),
              "modified_within_days": prop("integer", "Only files changed in the last N days, e.g. 1 for yesterday/today"),
              "location": prop("string", "Optional: desktop, documents, downloads or home")], required: []),
        tool("create_folder", "Create a new empty folder.",
             ["name": prop("string", "Folder name"),
              "location": prop("string", "desktop, documents, downloads or home (default desktop)")], required: ["name"]),
        tool("rename_item", "Rename an existing file or folder. The user is asked to confirm.",
             ["from": prop("string", "Current name"), "to": prop("string", "New name"),
              "location": prop("string", "desktop, documents, downloads or home (default desktop)")], required: ["from", "to"]),
        tool("create_reminder", "Add a reminder to the Reminders app.",
             ["title": prop("string", "What to be reminded about, e.g. Call HR"),
              "due": prop("string", "Optional due time as ISO 8601 with the user's UTC offset, e.g. 2026-10-03T17:00:00+05:30"),
              "notes": prop("string", "Optional notes")], required: ["title"]),
        tool("create_calendar_event", "Add an event to the user's default calendar.",
             ["title": prop("string", "Event title"),
              "start": prop("string", "Start as ISO 8601 with the user's UTC offset"),
              "end": prop("string", "Optional end as ISO 8601; default is one hour after start"),
              "location": prop("string", "Optional place"), "notes": prop("string", "Optional notes")],
             required: ["title", "start"]),
        tool("set_volume", "Change the Mac's sound volume.",
             ["action": prop("string", "set, up, down, mute or unmute"),
              "level": prop("integer", "For set: 0-100. For up/down: how much to change, default 15")], required: ["action"]),
        tool("set_brightness", "Make the built-in screen brighter or dimmer.",
             ["action": prop("string", "up or down"), "steps": prop("integer", "1-16, default 4")], required: ["action"]),
        tool("set_dark_mode", "Switch macOS dark mode.",
             ["mode": prop("string", "on, off or toggle")], required: ["mode"])
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "input_schema": ["type": "object", "properties": properties, "required": required]]
    }

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    static func systemPrompt(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm 'UTC'xxx"
        return """
        You are Bibbles, carrying out the user's spoken command on their Mac with the tools provided. The request may be in English or Hinglish and come from speech recognition, so fix obvious mis-hearings.
        Current local time: \(formatter.string(from: now)) (\(timeZone.identifier)). Resolve times like "tomorrow at 10" or "in 20 minutes" against this, and always include the UTC offset in dates.
        Call the tool or tools needed, in order, without asking follow-up questions; pick sensible defaults (desktop for folders, one hour for meetings). For "open X": use open_app for apps and open_website for websites (YouTube, Gmail, etc.).
        If no tool can do the request (for example deleting files, sending messages, Do Not Disturb), reply in one short sentence saying what you can do instead.
        """ + (ToolGate.isEnabled ? "\n" + ToolGate.replyLanguageRule : "")
    }

    static func plan(command: String, apiKey: String) async throws -> AgentPlan {
        if let plan = LockScreenCommand.localPlan(for: command) { return plan }
        if let plan = MusicRequest.localPlan(command) { return plan }
        let toolData = try JSONSerialization.data(withJSONObject: tools)
        let toolList = String(data: toolData, encoding: .utf8) ?? "[]"
        let answer = try await WorkerAPI.chat(mode: .ask, messages: [
            ["role": "system", "content": systemPrompt() + "\nAvailable tools: \(toolList)\nReturn ONLY JSON: {\"calls\":[{\"name\":\"tool_name\",\"input\":{}}],\"text\":\"optional brief explanation\"}. Use at most 5 calls. If no tool fits, use an empty calls array. Never output executable code."],
            ["role": "user", "content": String(command.prefix(2_000))]
        ], maxTokens: 700)
        return try parseWorkerPlan(answer)
    }

    static func parseWorkerPlan(_ text: String) throws -> AgentPlan {
        guard let data = ClaudeAPI.jsonObjectText(text).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["calls"] as? [[String: Any]] else {
            throw MacActionError.failed("the command couldn't be understood")
        }
        let allowed = Set(tools.compactMap { $0["name"] as? String })
        let calls = entries.prefix(5).compactMap { entry -> AgentToolCall? in
            guard let name = entry["name"] as? String, allowed.contains(name),
                  let values = entry["input"] as? [String: Any] else { return nil }
            return AgentToolCall(name: name, input: values.mapValues(AgentValue.init))
        }
        return AgentPlan(calls: calls, text: (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parse(_ data: Data) throws -> AgentPlan {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else {
            throw MacActionError.failed("the command couldn't be understood")
        }
        var calls: [AgentToolCall] = []
        var text = ""
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                let input = (block["input"] as? [String: Any] ?? [:]).mapValues(AgentValue.init)
                calls.append(AgentToolCall(name: name, input: input))
            case "text":
                text += block["text"] as? String ?? ""
            default:
                continue
            }
        }
        return AgentPlan(calls: Array(calls.prefix(5)), text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Tools that only look things up, or make small changes the user can undo
    /// in a second (volume, brightness, dark mode, showing a folder).
    static let harmlessTools: Set<String> = ["find_files", "open_folder", "set_volume", "set_brightness", "set_dark_mode"]

    /// The model chooses the tools, so anything lasting, or anything the user
    /// didn't clearly name, is shown to them and confirmed before it runs.
    /// (rename_item is confirmed separately, with the exact old and new names.)
    /// Second-level labels under a two-letter country code (bbc.co.uk, amazon.co.in).
    static let countrySecondLevels: Set<String> = ["co", "com", "net", "org", "gov", "ac", "edu", "gen", "firm", "ind", "nic", "res", "ltd", "plc"]

    /// The site's real name: the label just before its public suffix, e.g.
    /// "youtube" for www.youtube.com, "bbc" for news.bbc.co.uk, and "evil"
    /// (not "google") for google.com.evil.example.
    static func siteName(of host: String) -> String? {
        let labels = host.lowercased().split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard labels.count >= 2 else { return nil }
        let suffix = labels.count >= 3 && labels[labels.count - 1].count == 2
            && countrySecondLevels.contains(labels[labels.count - 2]) ? 2 : 1
        let name = labels[labels.count - 1 - suffix].filter { $0.isLetter || $0.isNumber }
        return name.isEmpty ? nil : name
    }

    /// Opens without asking only when the site's real name is a word (or two
    /// or three adjacent words, "you tube") the user actually said.
    static func siteMatchesRequest(host: String, command: String) -> Bool {
        guard let name = siteName(of: host), name.count >= 2 else { return false }
        let words = command.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for start in words.indices {
            var joined = ""
            for end in start..<min(start + 3, words.count) {
                joined += words[end]
                if joined == name { return true }
            }
        }
        return false
    }

    static func needsConfirmation(_ call: AgentToolCall, command: String) -> Bool {
        let said = AppLauncher.normalized(command)
        func named(_ value: String?) -> Bool {
            let wanted = AppLauncher.normalized(value ?? "")
            return !wanted.isEmpty && said.contains(wanted)
        }
        if harmlessTools.contains(call.name) || call.name == "rename_item" { return false }
        switch call.name {
        case "music":
            return MusicRequest.localPlan(command)?.calls.first != call
        case "lock_screen":
            return !LockScreenCommand.isImmediate(command)
        case "open_app":
            return !named(call.string("name"))
        case "open_website":
            guard let url = AppLauncher.websiteURL(from: call.string("url") ?? ""),
                  let host = url.host?.lowercased() else { return true }
            let isGoogleSearch = (host == "google.com" || host == "www.google.com") && url.path == "/search"
            return !(isGoogleSearch || siteMatchesRequest(host: host, command: command))
        case "create_folder":
            return !named(call.string("name"))
        default:
            // Reminders, calendar events and anything unknown: always confirm.
            return true
        }
    }

    /// A short, plain description of what a call will do, for the confirmation.
    static func describe(_ call: AgentToolCall) -> String {
        switch call.name {
        case "music": return "\(call.string("action") ?? "Control") music in \(call.string("app") ?? "the running player")\(call.string("query").map { ": " + $0 } ?? "")"
        case "lock_screen": return "Lock this Mac now, keeping your apps open"
        case "open_app": return "Open the app “\(call.string("name") ?? "?")”"
        case "open_website":
            let url = AppLauncher.websiteURL(from: call.string("url") ?? "")
            return "Open the website \(url?.host ?? call.string("url") ?? "?")"
        case "create_folder":
            let place = FileLocation(rawValue: (call.string("location") ?? "desktop").lowercased()) ?? .desktop
            return "Create a folder “\(call.string("name") ?? "?")” in \(place.displayName)"
        case "create_reminder":
            let due = CalendarActions.parseDate(call.string("due")).map { " for " + CalendarActions.formatted($0) } ?? ""
            return "Add the reminder “\(call.string("title") ?? "?")”" + due
        case "create_calendar_event":
            let start = CalendarActions.parseDate(call.string("start")).map { " on " + CalendarActions.formatted($0) } ?? ""
            return "Add the calendar event “\(call.string("title") ?? "?")”" + start
        default:
            return call.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Runs one tool call. `confirmRename` lets the app ask before renaming.
    @MainActor
    static func run(_ call: AgentToolCall, confirmRename: (String, String, String) -> Bool) async throws -> MacActionResult {
        let location = FileLocation(rawValue: (call.string("location") ?? "desktop").lowercased()) ?? .desktop
        switch call.name {
        case "music": return try await MusicAction(call).run()
        case "lock_screen":
            guard call.input.isEmpty else { throw MacActionError.failed("Lock Screen does not accept scheduling or other options.") }
            return try await LockScreenAction.run()
        case "open_app":
            return try await AppLauncher.open(appNamed: call.string("name") ?? "")
        case "open_website":
            return try AppLauncher.open(website: call.string("url") ?? "")
        case "open_folder":
            return try AppLauncher.open(folder: call.string("location") ?? "desktop")
        case "find_files":
            let kind = FileFinder.Kind(rawValue: (call.string("file_type") ?? "any").lowercased()) ?? .anyKind
            let scope = call.string("location").flatMap { FileLocation(rawValue: $0.lowercased()) }
            let name = call.string("name")
            let results = try await FileFinder.find(name: name, kind: kind,
                                                    modifiedWithinDays: call.int("modified_within_days"), in: scope)
            guard !results.isEmpty else { throw MacActionError.nothingFound(name ?? kind.rawValue) }
            NSWorkspace.shared.activateFileViewerSelecting([results[0]])
            let heading = results.count == 1 ? "Found 1 match (shown in Finder):" : "Found \(results.count) matches — the newest is shown in Finder:"
            return MacActionResult(message: heading + "\n" + FileFinder.describe(results), showsDetails: true)
        case "create_folder":
            let url = try FileActionExecutor.createFolder(named: call.string("name"), in: location)
            return MacActionResult(message: "Created folder “\(url.lastPathComponent)” in \(location.displayName)")
        case "rename_item":
            let source = try FileActionExecutor.findItem(named: call.string("from"), in: location)
            let destination = try FileActionExecutor.renameDestination(for: source, to: call.string("to"))
            guard confirmRename(source.lastPathComponent, destination.lastPathComponent, location.displayName) else {
                return MacActionResult(message: "Rename cancelled")
            }
            try FileActionExecutor.rename(source, to: destination, in: location)
            return MacActionResult(message: "Renamed “\(source.lastPathComponent)” to “\(destination.lastPathComponent)”")
        case "create_reminder":
            return try await CalendarActions.addReminder(title: call.string("title") ?? "", due: call.string("due"),
                                                         notes: call.string("notes"))
        case "create_calendar_event":
            return try await CalendarActions.addEvent(title: call.string("title") ?? "", start: call.string("start"),
                                                      end: call.string("end"), location: call.string("location"),
                                                      notes: call.string("notes"))
        case "set_volume":
            return try MacControls.volume(action: call.string("action") ?? "set", level: call.int("level"))
        case "set_brightness":
            return MacControls.brightness(action: call.string("action") ?? "up", steps: call.int("steps"))
        case "set_dark_mode":
            return try MacControls.darkMode(call.string("mode") ?? "toggle")
        default:
            throw MacActionError.unsupported("Bibbles can't do that yet.")
        }
    }
}
