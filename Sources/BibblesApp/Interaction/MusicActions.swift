import AppKit

enum MusicRequest {
    static func isRequest(_ text: String) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"^(?:hey bibbles[, ]+)?(?:(?:can|could|would) you )?(?:please )?"#
        return text.range(of: prefix + #"(?:(?:play|put on)\b.+|(?:skip|pause|resume|next|previous) (?:this |the |my )?(?:track|song|music|playback)\b|(?:open )?(?:spotify|apple music).*\b(?:play|bajao)\b)"#, options: .regularExpression) != nil
    }

    static func localPlan(_ text: String) -> AgentPlan? {
        var text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        if text.hasPrefix("please ") { text = String(text.dropFirst(7)) }
        var app = "auto"
        for (suffix, name) in [(" on spotify", "spotify"), (" on apple music", "apple_music"), (" in spotify", "spotify"), (" in apple music", "apple_music")] {
            if text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)); app = name; break }
        }
        let actions = ["skip this track": "next", "skip this song": "next", "next track": "next",
                       "previous track": "previous", "pause music": "pause", "pause the music": "pause",
                       "resume music": "resume", "resume playback": "resume"]
        guard let action = actions[text] else { return nil }
        return AgentPlan(calls: [AgentToolCall(name: "music", input: ["action": .string(action), "app": .string(app)])], text: "")
    }
}

enum MusicPlayer: String, CaseIterable {
    case spotify, appleMusic = "apple_music"
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var name: String { self == .spotify ? "Spotify" : "Apple Music" }
    private static let systemMusicPath = "/System/Applications/Music.app"

    var appleScriptTarget: String {
        self == .appleMusic
            ? "application \"\(Self.systemMusicPath)\""
            : "application id \"\(bundleID)\""
    }

    var installedURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        guard self == .appleMusic else { return nil }
        let url = URL(fileURLWithPath: Self.systemMusicPath)
        return Bundle(url: url)?.bundleIdentifier == bundleID ? url : nil
    }
}

struct MusicAction {
    enum Operation: String { case play, pause, resume, next, previous }
    let operation: Operation
    let player: MusicPlayer?
    let query: String
    let kind: String

    init(_ call: AgentToolCall) throws {
        guard let operation = Operation(rawValue: call.string("action") ?? ""),
              Set(call.input.keys).isSubset(of: ["action", "app", "query", "kind"]) else {
            throw MacActionError.failed("Unsupported music action.")
        }
        let app = call.string("app") ?? "auto"
        guard app == "auto" || MusicPlayer(rawValue: app) != nil else {
            throw MacActionError.failed("Choose Spotify or Apple Music.")
        }
        let query = (call.string("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = call.string("kind") ?? "song"
        guard query.count <= 300, !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ["song", "genre"].contains(kind), operation == .play || query.isEmpty else {
            throw MacActionError.failed("Invalid music search. Use a song, artist, or genre.")
        }
        self.operation = operation; self.player = MusicPlayer(rawValue: app); self.query = query; self.kind = kind
    }

    static func resolve(explicit: MusicPlayer?, running: [MusicPlayer]) throws -> MusicPlayer {
        if let explicit { return explicit }
        // A named player always wins. When the request doesn't name one, use
        // Apple's built-in player consistently instead of making the result
        // depend on which music apps happen to be open.
        return .appleMusic
    }

    static func searchURL(player: MusicPlayer, query: String) -> URL {
        var url = URLComponents(string: player == .spotify ? "https://open.spotify.com/search/" : "https://music.apple.com/search")!
        if player == .spotify { url.path += query }
        else { url.queryItems = [URLQueryItem(name: "term", value: query)] }
        return url.url!
    }

    // Only fixed app targets and fixed verbs enter the script. Search text is argv data.
    static func script(player: MusicPlayer, operation: Operation, search: Bool) -> String {
        let verb: String
        switch operation {
        case .play, .resume: verb = "play"
        case .pause: verb = "pause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        let body = search ? """
        set matches to search library playlist 1 for (item 1 of argv)
        if (count of matches) is 0 then return "NO_MATCH"
        if (count of matches) > 1 then return "AMBIGUOUS"
        play item 1 of matches
        return "PLAY_REQUESTED"
        """ : "\(verb)\nreturn \"CONTROL_REQUESTED\""
        return "on run argv\nwith timeout of 12 seconds\ntell \(player.appleScriptTarget)\n\(body)\nend tell\nend timeout\nend run"
    }

    @MainActor
    func run() async throws -> MacActionResult {
        try Task.checkCancellation()
        let running = MusicPlayer.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
        let player = try Self.resolve(explicit: player, running: running)
        guard player.installedURL != nil else {
            throw MacActionError.appNotFound(player.name)
        }
        if operation == .play, !query.isEmpty, player == .spotify { return try openSearch(player) }
        let script = Self.script(player: player, operation: operation, search: !query.isEmpty)
        let result = try await Self.execute(script: script, query: query, player: player)
        try Task.checkCancellation()
        if result == "NO_MATCH" || result == "AMBIGUOUS" {
            guard player == .appleMusic else { return try openSearch(player) }
            guard #available(macOS 14.0, *) else {
                throw MacActionError.failed("Catalog playback requires macOS 14 or newer. This track isn't in your local Music library.")
            }
            return try await AppleMusicCatalog.play(query: query, kind: kind == "genre" ? .genre : .song)
        }
        return MacActionResult(message: "\(operation.rawValue.capitalized) requested in \(player.name)\(query.isEmpty ? "" : ": \(query)").")
    }

    @MainActor
    private func openSearch(_ player: MusicPlayer) throws -> MacActionResult {
        try Task.checkCancellation()
        guard NSWorkspace.shared.open(Self.searchURL(player: player, query: query)) else {
            throw MacActionError.failed("Couldn't open \(player.name) search.")
        }
        return MacActionResult(message: "Opened \(player.name) results for ‘\(query)’. Select a result and press Play. I haven't started playback.", showsDetails: true)
    }

    private static func execute(script: String, query: String, player: MusicPlayer) async throws -> String {
        // Process runs off the UI actor. Cancellation is propagated to the worker.
        let worker = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, query]
            let output = Pipe(); let errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw MacActionError.failed("\(player.name) didn't respond. Check its Automation permission and try again.") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard process.terminationStatus == 0 else {
                let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if error.contains("-1743") {
                    throw MacActionError.failed("Allow Bibbles → \(player.name) in System Settings → Privacy & Security → Automation.")
                }
                throw MacActionError.failed("\(player.name) couldn't perform that action. Open the player, sign in, and select a playable track first.")
            }
            return (String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
