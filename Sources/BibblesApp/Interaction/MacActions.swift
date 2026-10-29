import AppKit
import EventKit
import Foundation

/// The result of one action, shown to the user.
struct MacActionResult {
    let message: String
    /// Longer results (like a file list) are shown in the answer card.
    var showsDetails = false
}

enum MacActionError: LocalizedError {
    case appNotFound(String)
    case invalidURL(String)
    case noSearchTerms
    case nothingFound(String)
    case invalidDate(String)
    case calendarAccessDenied
    case remindersAccessDenied
    case automationDenied
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name): return "Bibbles couldn't find an app called “\(name)” on this Mac."
        case .invalidURL(let value): return "“\(value)” isn't a website address Bibbles can open."
        case .noSearchTerms: return "Tell Bibbles what to look for, for example “find my resume PDF”."
        case .nothingFound(let query): return "No files matching “\(query)” were found."
        case .invalidDate(let value): return "Bibbles couldn't understand the time “\(value)”. Try saying the date and time again."
        case .calendarAccessDenied:
            return "Bibbles needs Calendar access. Allow it in System Settings → Privacy & Security → Calendars, then try again."
        case .remindersAccessDenied:
            return "Bibbles needs Reminders access. Allow it in System Settings → Privacy & Security → Reminders, then try again."
        case .automationDenied:
            return "Bibbles needs permission to change this setting. Allow Bibbles → System Events in System Settings → Privacy & Security → Automation."
        case .unsupported(let what): return what
        case .failed(let message): return "Bibbles couldn't do that: \(message)"
        }
    }
}

// MARK: - Apps, websites and folders

@MainActor
enum AppLauncher {
    private static var searchDirectories: [URL] {
        var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", "/System/Library/CoreServices/Applications"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true))
        return dirs
    }

    static func installedApps() -> [URL] {
        var apps: [URL] = []
        let manager = FileManager.default
        for dir in searchDirectories {
            guard let items = try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    apps.append(item)
                } else if let nested = try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles]) {
                    apps.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                }
            }
        }
        return apps
    }

    nonisolated static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Best installed app for a spoken name: exact, then prefix, then contains.
    nonisolated static func bestMatch(for name: String, in apps: [URL]) -> URL? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        let named = apps.map { ($0, normalized($0.deletingPathExtension().lastPathComponent)) }
        if let exact = named.first(where: { $0.1 == wanted }) { return exact.0 }
        if let prefix = named.filter({ $0.1.hasPrefix(wanted) }).min(by: { $0.1.count < $1.1.count }) { return prefix.0 }
        if let contains = named.filter({ $0.1.contains(wanted) }).min(by: { $0.1.count < $1.1.count }) { return contains.0 }
        return nil
    }

    static func open(appNamed name: String) async throws -> MacActionResult {
        guard let url = bestMatch(for: name, in: installedApps()) else { throw MacActionError.appNotFound(name) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw MacActionError.failed(error.localizedDescription)
        }
        return MacActionResult(message: "Opened \(url.deletingPathExtension().lastPathComponent)")
    }

    nonisolated static func websiteURL(from raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    static func open(website raw: String) throws -> MacActionResult {
        guard let url = websiteURL(from: raw) else { throw MacActionError.invalidURL(raw) }
        guard NSWorkspace.shared.open(url) else { throw MacActionError.failed("the browser didn't open") }
        return MacActionResult(message: "Opened \(url.host ?? url.absoluteString)")
    }

    static func open(folder location: String) throws -> MacActionResult {
        let url: URL
        let name: String
        if location.lowercased() == "applications" {
            url = URL(fileURLWithPath: "/Applications", isDirectory: true)
            name = "Applications"
        } else {
            let place = FileLocation(rawValue: location.lowercased()) ?? .desktop
            guard let placeURL = place.url else { throw MacActionError.failed("that folder is unavailable") }
            url = placeURL
            name = place.displayName
        }
        guard NSWorkspace.shared.open(url) else { throw MacActionError.failed("Finder didn't open \(name)") }
        return MacActionResult(message: "Opened \(name)")
    }
}

// MARK: - Finding files (Spotlight)

enum FileFinder {
    enum Kind: String {
        case anyKind = "any", pdf, image, video, audio, folder, word, spreadsheet, presentation, text

        var contentType: String? {
            switch self {
            case .anyKind: return nil
            case .pdf: return "com.adobe.pdf"
            case .image: return "public.image"
            case .video: return "public.movie"
            case .audio: return "public.audio"
            case .folder: return "public.folder"
            case .word: return "org.openxmlformats.wordprocessingml.document"
            case .spreadsheet: return "org.openxmlformats.spreadsheetml.sheet"
            case .presentation: return "org.openxmlformats.presentationml.presentation"
            case .text: return "public.text"
            }
        }
    }

    /// Spotlight query text; quotes, wildcards and backslashes are removed
    /// from the user's words so they can't change the query.
    static func query(name: String?, kind: Kind, modifiedWithinDays: Int?) -> String? {
        var parts: [String] = []
        let cleaned = (name ?? "")
            .replacingOccurrences(of: #"["*\\$()]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for word in cleaned.split(separator: " ").prefix(4) where !word.isEmpty {
            parts.append("kMDItemFSName == \"*\(word)*\"cd")
        }
        if let type = kind.contentType { parts.append("kMDItemContentTypeTree == \"\(type)\"") }
        if let days = modifiedWithinDays, days > 0 {
            parts.append("kMDItemFSContentChangeDate >= $time.today(-\(min(days, 3650)))")
        }
        guard !parts.isEmpty, !(cleaned.isEmpty && kind == .anyKind && modifiedWithinDays == nil) else { return nil }
        return parts.joined(separator: " && ")
    }

    static func find(name: String?, kind: Kind, modifiedWithinDays: Int?, in location: FileLocation?) async throws -> [URL] {
        guard let query = query(name: name, kind: kind, modifiedWithinDays: modifiedWithinDays) else {
            throw MacActionError.noSearchTerms
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scope = location?.url ?? home
        let output: String = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", scope.path, query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { process.terminate() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value

        let library = home.appendingPathComponent("Library").path
        let urls = output.split(separator: "\n").prefix(400).map { URL(fileURLWithPath: String($0)) }
            .filter { !$0.path.hasPrefix(library) && !$0.path.contains("/.") && !$0.path.contains(".app/") }
        let dated = urls.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, date)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
    }

    static func describe(_ urls: [URL]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return urls.map { url in
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            return "• \(url.lastPathComponent) — \(folder)"
        }.joined(separator: "\n")
    }
}

// MARK: - Reminders and calendar

@MainActor
enum CalendarActions {
    private static let store = EKEventStore()

    nonisolated static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: raw) { return date }
        }
        return nil
    }

    nonisolated static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private static func requestReminderAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToReminders()
        } else {
            granted = try await store.requestAccess(to: .reminder)
        }
        if !granted { throw MacActionError.remindersAccessDenied }
    }

    private static func requestEventAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestWriteOnlyAccessToEvents()
        } else {
            granted = try await store.requestAccess(to: .event)
        }
        if !granted { throw MacActionError.calendarAccessDenied }
    }

    static func addReminder(title: String, due rawDue: String?, notes: String?) async throws -> MacActionResult {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw MacActionError.failed("the reminder needs a title") }
        let due = parseDate(rawDue)
        if rawDue?.isEmpty == false, due == nil { throw MacActionError.invalidDate(rawDue ?? "") }
        try await requestReminderAccess()
        guard let list = store.defaultCalendarForNewReminders() else {
            throw MacActionError.failed("no default Reminders list is set up")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = String(cleanTitle.prefix(300))
        reminder.calendar = list
        if let notes, !notes.isEmpty { reminder.notes = String(notes.prefix(2_000)) }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do { try store.save(reminder, commit: true) } catch { throw MacActionError.failed(error.localizedDescription) }
        let when = due.map { " for \(formatted($0))" } ?? ""
        return MacActionResult(message: "Reminder added: “\(reminder.title ?? cleanTitle)”\(when)")
    }

    static func addEvent(title: String, start rawStart: String?, end rawEnd: String?,
                         location: String?, notes: String?) async throws -> MacActionResult {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw MacActionError.failed("the event needs a title") }
        guard let start = parseDate(rawStart) else { throw MacActionError.invalidDate(rawStart ?? "no time given") }
        let end = parseDate(rawEnd).flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3_600)
        try await requestEventAccess()
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw MacActionError.failed("no default calendar is set up")
        }
        let event = EKEvent(eventStore: store)
        event.title = String(cleanTitle.prefix(300))
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        if let location, !location.isEmpty { event.location = String(location.prefix(300)) }
        if let notes, !notes.isEmpty { event.notes = String(notes.prefix(2_000)) }
        do { try store.save(event, span: .thisEvent, commit: true) } catch { throw MacActionError.failed(error.localizedDescription) }
        return MacActionResult(message: "Added “\(cleanTitle)” to your calendar, \(formatted(start))")
    }
}

// MARK: - Mac controls

@MainActor
enum MacControls {
    @discardableResult
    private static func runAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw MacActionError.failed("script error") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 || number == -1744 { throw MacActionError.automationDenied }
            throw MacActionError.failed(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(number)")
        }
        return result
    }

    static func currentVolume() -> Int {
        guard let descriptor = try? runAppleScript("output volume of (get volume settings)") else { return 50 }
        return Int(descriptor.int32Value)
    }

    static func volume(action: String, level: Int?) throws -> MacActionResult {
        switch action.lowercased() {
        case "mute":
            try runAppleScript("set volume with output muted")
            return MacActionResult(message: "Sound muted")
        case "unmute":
            try runAppleScript("set volume without output muted")
            return MacActionResult(message: "Sound unmuted")
        case "up", "down":
            let step = max(1, min(level ?? 15, 100))
            let target = max(0, min(100, currentVolume() + (action.lowercased() == "up" ? step : -step)))
            try runAppleScript("set volume without output muted\nset volume output volume \(target)")
            return MacActionResult(message: "Volume \(target)%")
        default:
            let target = max(0, min(100, level ?? 50))
            try runAppleScript("set volume without output muted\nset volume output volume \(target)")
            return MacActionResult(message: "Volume set to \(target)%")
        }
    }

    /// Presses the system brightness keys (works for built-in displays).
    static func brightness(action: String, steps: Int?) -> MacActionResult {
        let up = action.lowercased() != "down"
        let count = max(1, min(steps ?? 4, 16))
        let key: Int = up ? 2 : 3 // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        for _ in 0..<count {
            for down in [true, false] {
                let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
                let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
                let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                               timestamp: 0, windowNumber: 0, context: nil,
                                               subtype: 8, data1: data1, data2: -1)
                event?.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        return MacActionResult(message: up ? "Brightness up" : "Brightness down")
    }

    static func darkMode(_ mode: String) throws -> MacActionResult {
        let value: String
        switch mode.lowercased() {
        case "on", "true", "dark": value = "true"
        case "off", "false", "light": value = "false"
        default: value = "not dark mode"
        }
        try runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
        let isDark = (try? runAppleScript("tell application \"System Events\" to tell appearance preferences to get dark mode"))?.booleanValue
        return MacActionResult(message: isDark == false ? "Light mode on" : "Dark mode on")
    }
}
