import Foundation

/// Folders Bibbles may create or rename items in.
enum FileLocation: String, CaseIterable {
    case desktop, documents, downloads, home

    var url: URL? {
        let manager = FileManager.default
        switch self {
        case .desktop: return manager.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .documents: return manager.urls(for: .documentDirectory, in: .userDomainMask).first
        case .downloads: return manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .home: return manager.homeDirectoryForCurrentUser
        }
    }

    var displayName: String {
        switch self {
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .home: return "your home folder"
        }
    }
}

struct FileActionPlan: Equatable {
    enum Action: String {
        case createFolder = "create_folder"
        case rename
        case none
    }

    let action: Action
    let location: FileLocation
    let name: String?
    let from: String?
    let to: String?
    let note: String?
}

enum FileActionError: LocalizedError, Equatable {
    case unsupported(String)
    case invalidName
    case alreadyExists(String, String)
    case notFound(String, String)
    case ambiguous(String, String)
    case permission(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let note):
            return note.isEmpty ? "Bibbles can create folders and rename files or folders. It doesn't delete or move files." : note
        case .invalidName:
            return "That name can't be used for a file or folder. Try a name without / or : characters."
        case let .alreadyExists(name, place):
            return "“\(name)” already exists in \(place). Bibbles didn't change anything."
        case let .notFound(name, place):
            return "Bibbles couldn't find “\(name)” in \(place). Check the name and try again."
        case let .ambiguous(name, place):
            return "More than one item in \(place) matches “\(name)”. Say the full name, including the extension (for example .pdf)."
        case .permission(let place):
            return "Bibbles needs access to \(place). Allow it in System Settings → Privacy & Security → Files and Folders, then try again."
        case .failed(let message):
            return "Bibbles couldn't complete that: \(message)"
        }
    }
}

/// Performs file actions. Deliberately limited: create folders and rename
/// items inside a few user folders. Never deletes, moves or overwrites.
enum FileActionExecutor {
    static func cleanName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`")
        name = name.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200,
              !name.contains("/"), !name.contains(":"),
              name != ".", name != "..", !name.hasPrefix(".") else { return nil }
        return name
    }

    @discardableResult
    static func createFolder(named rawName: String?, in location: FileLocation) throws -> URL {
        guard let name = cleanName(rawName) else { throw FileActionError.invalidName }
        guard let base = location.url else { throw FileActionError.failed("the \(location.displayName) folder is unavailable") }
        let target = base.appendingPathComponent(name, isDirectory: true)
        guard target.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL else {
            throw FileActionError.invalidName
        }
        if FileManager.default.fileExists(atPath: target.path) {
            throw FileActionError.alreadyExists(name, location.displayName)
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            throw mapped(error, location: location)
        }
        return target
    }

    /// Finds the item to rename. Matches the exact name first, then the name
    /// without its extension (so "report" finds "report.pdf").
    static func findItem(named rawName: String?, in location: FileLocation) throws -> URL {
        guard let name = cleanName(rawName) else { throw FileActionError.invalidName }
        guard let base = location.url else { throw FileActionError.failed("the \(location.displayName) folder is unavailable") }
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])
        } catch {
            throw mapped(error, location: location)
        }
        let lower = name.lowercased()
        let exact = items.filter { $0.lastPathComponent.lowercased() == lower }
        if exact.count == 1 { return exact[0] }
        let byStem = items.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == lower }
        if byStem.count == 1 { return byStem[0] }
        if exact.count > 1 || byStem.count > 1 { throw FileActionError.ambiguous(name, location.displayName) }
        throw FileActionError.notFound(name, location.displayName)
    }

    /// The new URL for a rename, keeping the original extension when the new
    /// name doesn't include one.
    static func renameDestination(for source: URL, to rawName: String?) throws -> URL {
        guard var name = cleanName(rawName) else { throw FileActionError.invalidName }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let ext = source.pathExtension
        if !isDirectory.boolValue, !ext.isEmpty, (name as NSString).pathExtension.isEmpty {
            name += ".\(ext)"
        }
        return source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isDirectory.boolValue)
    }

    static func rename(_ source: URL, to destination: URL, in location: FileLocation) throws {
        guard source.deletingLastPathComponent().standardizedFileURL
                == destination.deletingLastPathComponent().standardizedFileURL else {
            throw FileActionError.invalidName
        }
        let caseOnlyChange = source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
        if !caseOnlyChange, FileManager.default.fileExists(atPath: destination.path) {
            throw FileActionError.alreadyExists(destination.lastPathComponent, location.displayName)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw mapped(error, location: location)
        }
    }

    private static func mapped(_ error: Error, location: FileLocation) -> FileActionError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return .permission(location.displayName)
        }
        if ns.domain == NSPOSIXErrorDomain, [1, 13].contains(ns.code) { // EPERM, EACCES
            return .permission(location.displayName)
        }
        return .failed(ns.localizedDescription)
    }
}

/// Asks Claude to turn a spoken request into one file action.
enum ClaudeFileActionPlanner {
    static let basePrompt = """
    You convert a user's spoken request into exactly one file action on their Mac. The request may be in English or Hinglish and may come from speech recognition.
    Return one JSON object only, with no text before or after it:
    {"action":"create_folder","location":"desktop","name":"Mohit","from":null,"to":null,"note":""}
    action: "create_folder" to make a new empty folder, "rename" to rename an existing file or folder, or "none" for anything else.
    location: "desktop", "documents", "downloads" or "home". Use "desktop" when no place is mentioned (for example "desktop screen" means desktop).
    For create_folder put the folder name in "name". For rename put the current name in "from" and the new name in "to"; include a file extension only if the user said one.
    Keep names exactly as spoken, with natural capitalization of names (for example Mohit), and without surrounding quotes or words like "named" or "called".
    Deleting, moving, copying, opening or anything else is not supported: return action "none" with a short note explaining that.
    """

    /// The prompt sent; with the Tool Gate on it also carries the reply-language rule.
    static var systemPrompt: String {
        ToolGate.isEnabled ? basePrompt + "\n" + ToolGate.replyLanguageRule : basePrompt
    }

    static func plan(userRequest: String, apiKey: String) async throws -> FileActionPlan {
        var request = ClaudeAPI.request(apiKey: apiKey, timeout: 30)
        let body: [String: Any] = [
            "model": ClaudeAPI.model,
            "max_tokens": 300,
            "system": systemPrompt,
            "messages": [["role": "user", "content": String(userRequest.prefix(1_000))]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await ClaudeAPI.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = ChatHTTPError.friendly(status: status, body: String(data: data, encoding: .utf8) ?? "")
            throw FileActionError.failed(message)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> FileActionPlan {
        guard let text = ClaudeAPI.responseText(from: data),
              let json = ClaudeAPI.jsonObjectText(text).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw FileActionError.failed("the request couldn't be understood")
        }
        let action = FileActionPlan.Action(rawValue: (object["action"] as? String ?? "none").lowercased()) ?? .none
        let location = FileLocation(rawValue: (object["location"] as? String ?? "desktop").lowercased()) ?? .desktop
        return FileActionPlan(
            action: action,
            location: location,
            name: object["name"] as? String,
            from: object["from"] as? String,
            to: object["to"] as? String,
            note: object["note"] as? String
        )
    }
}
