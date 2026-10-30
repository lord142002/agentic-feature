import AVFoundation
import Combine
import Foundation

enum VoiceReplyError: LocalizedError {
    case invalidAudio(String), service(String, Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "Bibbles received audio it could not play. Please retry."
        case .service: return "Voice is temporarily unavailable. Please retry."
        }
    }
}

/// The audio-device boundary, injectable so cancellation tests never need to
/// play through the user's speakers or contact a metered AI endpoint.
@MainActor
protocol VoicePlayback: AnyObject {
    var enableRate: Bool { get set }
    var rate: Float { get set }
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    @discardableResult func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: VoicePlayback {}

/// Authenticated cloud speech through Bibbles' Worker. The Worker returns
/// raw 24 kHz mono PCM, which is wrapped locally as WAV for AVAudioPlayer.
@MainActor
final class VoiceReplyController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPlaying = false
    /// Runs once per answer, the moment its first audio starts playing (the
    /// answer card waits for it, so text and voice start together).
    var onSpeechStarted: (() -> Void)?
    private var startedGeneration: UUID?
    /// Changes whenever speech stops or a new answer starts.
    var generationID: UUID { generation }
    /// The current answer's voice has started.
    var hasStartedCurrent: Bool { startedGeneration == generation }

    private func markStarted(_ id: UUID) {
        guard id == generation, startedGeneration != id else { return }
        startedGeneration = id
        onSpeechStarted?()
    }
    @Published private(set) var errorMessage: String?
    /// How many pieces are generated ahead of the one playing.
    static let prefetchAhead = 1
    static var speed: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "bibbles.voiceSpeed")
            return value > 0 ? value : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: "bibbles.voiceSpeed") }
    }
    static var playbackRate: Float { Float(min(max(speed, 0.5), 1.8)) }

    typealias Synthesize = @Sendable (String, String) async throws -> Data
    typealias MakePlayback = @MainActor (Data) throws -> any VoicePlayback

    private let synthesize: Synthesize
    private let makePlayback: MakePlayback
    private var player: (any VoicePlayback)?
    private var speechTask: Task<Void, Error>?
    private var generation = UUID()
    private var lastText = ""

    init(session: URLSession = .shared, synthesize: Synthesize? = nil,
         makePlayback: @escaping MakePlayback = { try AVAudioPlayer(data: $0) }) {
        self.synthesize = synthesize ?? { text, voice in
            try Task.checkCancellation()
            return try await WorkerAPI.speechPCM(text: text, voice: voice, session: session)
        }
        self.makePlayback = makePlayback
    }

    func stop() {
        stop(keepingCue: false)
    }

    /// `keepingCue`: a new answer starting keeps "Ok, let me think first"
    /// playing; the answer waits for it to finish instead of cutting it off.
    private func stop(keepingCue: Bool) {
        if !keepingCue {
            cueTask?.cancel()
            cueTask = nil
            cuePlayer?.stop()
            cuePlayer = nil
        }
        generation = UUID()
        speechTask?.cancel()
        speechTask = nil
        streamTask?.cancel()
        streamTask = nil
        player?.stop()
        player = nil
        lastText = ""
        isActive = false
        isPlaying = false
        streamSource = ""
        streamConsumed = 0
        streamQueue.removeAll()
        streamEnded = false
    }

    func test() async -> Result<Void, Error> {
        await speakAndWait("Hi, I'm Bibbles. Voice replies are working.")
    }

    /// `voice`: a Gemini voice to use just this once (Settings previews);
    /// nil uses the saved voice.
    func speakAndWait(_ text: String, voice: String? = nil) async -> Result<Void, Error> {
        speak(text, voice: voice)
        guard let task = speechTask else { return .success(()) }
        do { try await task.value; return .success(()) }
        catch { return .failure(error) }
    }

    func speak(_ text: String, voice: String? = nil) {
        stop(keepingCue: true)
        errorMessage = nil
        let cleaned = VoiceReplyText.spoken(text)
        guard !cleaned.isEmpty else { return }
        play(VoiceReplyText.speechChunks(cleaned).map { SpeechPiece(text: $0) }, voice: voice, onStep: nil)
    }

    /// Speaks a walkthrough one step at a time. `onStep(i)` runs the moment
    /// step i starts playing, so its drawing appears with its sentence. A
    /// step with nothing to say still shows, after a short pause.
    func speakSteps(_ steps: [String], voice: String? = nil, onStep: @escaping (Int) -> Void) {
        stop(keepingCue: true)
        errorMessage = nil
        let pieces = VoiceReplyText.stepPieces(steps.map { VoiceReplyText.spoken($0) })
        guard !pieces.isEmpty else { return }
        play(pieces, voice: voice, onStep: onStep)
    }

    /// Plays pieces in order. Pieces are generated ahead while earlier ones
    /// play, so there is no silent wait for the server between sentences.
    private func play(_ pieces: [SpeechPiece], voice: String?, onStep: ((Int) -> Void)?) {
        let id = generation
        // The same voice for every language: Gemini voices are multilingual.
        let chosenVoice = voice ?? OpenRouterSpeech.englishVoice
        isActive = true
        speechTask = Task { [weak self] in
            guard let self else { return }
            let synthesize = self.synthesize
            var fetches: [Int: Task<Data, Error>] = [:]
            func fetch(_ index: Int) -> Task<Data, Error> {
                let text = pieces[index].text
                if text.isEmpty { return Task { Data() } }
                return Task {
                    try Task.checkCancellation()
                    return try await synthesize(text, chosenVoice)
                }
            }
            defer { fetches.values.forEach { $0.cancel() } }
            do {
                for index in 0..<min(Self.prefetchAhead + 1, pieces.count) { fetches[index] = fetch(index) }
                for index in pieces.indices {
                    try Task.checkCancellation()
                    guard let pending = fetches.removeValue(forKey: index) else { break }
                    // A failed metered piece stops this playback. Do not
                    // silently omit sentences or keep charging for later ones.
                    let pcm = try await withTaskCancellationHandler {
                        try await pending.value
                    } onCancel: {
                        pending.cancel()
                    }
                    try Task.checkCancellation()
                    guard self.generation == id else { throw CancellationError() }
                    // Keep the next pieces generating while this one plays.
                    let next = index + Self.prefetchAhead + 1
                    if next < pieces.count { fetches[next] = fetch(next) }
                    if pcm.isEmpty {
                        // A deliberately silent walkthrough step still shows
                        // its drawing at reading pace.
                        let piece = pieces[index]
                        let words = Double(max(piece.text.split(whereSeparator: \.isWhitespace).count, 1))
                        let seconds = piece.text.isEmpty ? 1.5 : max(1.5, words / 2.8)
                        var elapsed = 0.0
                        for mark in piece.marks {
                            let wait = mark.at * seconds - elapsed
                            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); elapsed += wait }
                            onStep?(mark.step)
                        }
                        try await Task.sleep(nanoseconds: UInt64(max(seconds - elapsed, 0) * 1_000_000_000))
                        continue
                    }
                    let wav = OpenRouterSpeech.wav(fromPCM: pcm, sampleRate: 24_000)
                    let playback = try self.makePlayback(wav)
                    playback.enableRate = true
                    playback.rate = Self.playbackRate
                    playback.prepareToPlay()
                    try await self.waitForCue(generation: id)
                    guard playback.play() else { throw VoiceReplyError.invalidAudio("Bibbles") }
                    self.markStarted(id)
                    // Each step's drawing appears when the voice reaches it.
                    var pendingMarks = pieces[index].marks[...]
                    @MainActor func fireReached() {
                        let progress = playback.duration > 0 ? playback.currentTime / playback.duration : 0
                        while let mark = pendingMarks.first, mark.at <= progress {
                            pendingMarks.removeFirst()
                            onStep?(mark.step)
                        }
                    }
                    fireReached()
                    self.player = playback
                    self.isPlaying = true
                    while playback.isPlaying {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        fireReached()
                    }
                    try Task.checkCancellation()
                    guard self.generation == id else { throw CancellationError() }
                    pendingMarks.forEach { onStep?($0.step) }
                    self.player = nil
                    self.isPlaying = false
                }
                if self.generation == id { self.isActive = false; self.speechTask = nil }
            } catch {
                if self.generation == id {
                    self.isActive = false
                    self.isPlaying = false
                    self.player = nil
                    self.speechTask = nil
                    if !Self.isCancellation(error) {
                        self.errorMessage = error.localizedDescription
                        Diagnostics.log("voice", ["event": "stopped", "error": Self.describe(error)])
                    }
                }
                throw error
            }
        }
    }

    /// The kind of error only (never any text), for the diagnostics log.
    nonisolated static func describe(_ error: Error) -> String {
        if let worker = error as? WorkerError { return String("worker.\(worker)".prefix(60)) }
        if let url = error as? URLError { return "url.\(url.code.rawValue)" }
        return String(describing: type(of: error))
    }

    // MARK: Thinking cue ("Ok, let me think first")

    private var cuePlayer: (any VoicePlayback)?
    private var cueTask: Task<Void, Never>?

    /// Plays one of the short saved "thinking" lines in the user's voice. Each
    /// line is made once per voice, saved on this Mac and then played from the
    /// file (no server request). Missing lines are made in the background and
    /// are ready next time; nothing plays until a saved one exists.
    func playThinkingCue() {
        let voice = OpenRouterSpeech.englishVoice
        let lines = ThinkingCueCache.lines
        let start = ThinkingCueCache.nextIndex()
        // The next saved line, starting from the rotation point.
        let saved = (0..<lines.count).map { (start + $0) % lines.count }
            .first { ThinkingCueCache.load(line: $0, voice: voice) != nil }
        if let index = saved, let wav = ThinkingCueCache.load(line: index, voice: voice),
           let playback = try? makePlayback(wav) {
            cuePlayer?.stop()
            playback.enableRate = true
            playback.rate = Self.playbackRate
            playback.prepareToPlay()
            if playback.play() { cuePlayer = playback }
        }
        prepareThinkingCues()
    }

    /// Makes any missing thinking lines once, quietly in the background
    /// (three short requests the very first time, then never again).
    func prepareThinkingCues() {
        let voice = OpenRouterSpeech.englishVoice
        let synthesize = self.synthesize
        let lines = ThinkingCueCache.lines
        let missing = lines.indices.filter { ThinkingCueCache.load(line: $0, voice: voice) == nil }
        guard !missing.isEmpty, cueTask == nil else { return }
        cueTask = Task { [weak self] in
            for index in missing {
                guard !Task.isCancelled else { break }
                if let pcm = try? await synthesize(lines[index], voice), !Task.isCancelled {
                    ThinkingCueCache.save(OpenRouterSpeech.wav(fromPCM: pcm, sampleRate: 24_000), line: index, voice: voice)
                }
            }
            self?.cueTask = nil
        }
    }

    /// The answer starts only after the thinking line has finished.
    private func waitForCue(generation id: UUID) async throws {
        while let cue = cuePlayer, cue.isPlaying {
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        cuePlayer = nil
    }

    /// A clip stopped on purpose (a newer clip started, or the user
    /// stopped it): Swift task cancellation or a cancelled network request.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: Voice previews (Settings → Voice)

    /// Plays the short preview line in `voice`. The first time, the server
    /// makes it and it is saved on this Mac; afterwards it plays instantly
    /// from the saved file (no server request, no allowance used).
    func playPreview(voice: String) async -> Result<Void, Error> {
        stop()
        errorMessage = nil
        let id = generation
        isActive = true
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            do {
                let wav: Data
                if let saved = VoicePreviewCache.load(voice: voice) {
                    wav = saved
                } else {
                    let pcm = try await self.synthesize(VoicePreviewCache.line, voice)
                    try Task.checkCancellation()
                    wav = OpenRouterSpeech.wav(fromPCM: pcm, sampleRate: 24_000)
                    VoicePreviewCache.save(wav, voice: voice)
                }
                guard self.generation == id else { throw CancellationError() }
                let playback = try self.makePlayback(wav)
                playback.enableRate = true
                playback.rate = Self.playbackRate
                playback.prepareToPlay()
                guard playback.play() else { throw VoiceReplyError.invalidAudio("Bibbles") }
                self.player = playback
                self.isPlaying = true
                while playback.isPlaying {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try Task.checkCancellation()
                guard self.generation == id else { throw CancellationError() }
                self.player = nil
                self.isPlaying = false
                if self.generation == id { self.isActive = false; self.speechTask = nil }
            } catch {
                if self.generation == id {
                    self.isActive = false
                    self.isPlaying = false
                    self.player = nil
                    self.speechTask = nil
                    if !Self.isCancellation(error) { self.errorMessage = error.localizedDescription }
                }
                throw error
            }
        }
        speechTask = task
        do { try await task.value; return .success(()) }
        catch { return .failure(error) }
    }

    private var isPrefetchingPreviews = false

    /// Saves every voice's preview on this Mac in the background (once per
    /// voice), so the first click on a voice card is instant too.
    func prefetchPreviews() {
        guard !isPrefetchingPreviews, AccountSession.shared.email != nil || Backends.isLocal else { return }
        let missing = OpenRouterSpeech.englishVoices.map(\.id).filter { VoicePreviewCache.load(voice: $0) == nil }
        guard !missing.isEmpty else { return }
        isPrefetchingPreviews = true
        Task { [weak self] in
            for voice in missing {
                guard let self else { return }
                if let pcm = try? await self.synthesize(VoicePreviewCache.line, voice) {
                    VoicePreviewCache.save(OpenRouterSpeech.wav(fromPCM: pcm, sampleRate: 24_000), voice: voice)
                }
            }
            self?.isPrefetchingPreviews = false
        }
    }

    /// Live answers: each sentence is spoken as soon as it is written on the
    /// card, while the AI is still writing the rest. Call with the whole
    /// answer so far on every update, and `final: true` once it is done.
    func accept(_ text: String, final: Bool) {
        // The same finished answer again: it was already spoken.
        if streamTask == nil, text == lastText { return }
        // A different answer (not a continuation of this one): start over.
        if streamTask == nil || !text.hasPrefix(streamSource.prefix(streamConsumed)) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            startStream()
        }
        streamSource = text
        let remaining = String(text.dropFirst(streamConsumed))
        let (ready, tail) = VoiceReplyText.readyChunks(in: remaining, final: final, limit: 320,
                                                         quickStart: streamConsumed == 0)
        streamConsumed = text.count - tail.count
        streamQueue += VoiceReplyText.groupLive(ready, firstPiece: streamQueue.isEmpty)
        if final { streamEnded = true; lastText = text }
    }

    private var streamTask: Task<Void, Never>?
    private var streamSource = ""
    private var streamConsumed = 0
    private var streamQueue: [String] = []
    private var streamEnded = false

    private func startStream() {
        stop(keepingCue: true)
        errorMessage = nil
        streamSource = ""
        streamConsumed = 0
        streamQueue = []
        streamEnded = false
        let id = generation
        let chosenVoice = OpenRouterSpeech.englishVoice
        let synthesize = self.synthesize
        isActive = true
        streamTask = Task { [weak self] in
            var fetches: [Int: Task<Data, Error>] = [:]
            defer { fetches.values.forEach { $0.cancel() } }
            var index = 0
            func fetch(_ i: Int, _ text: String) {
                guard fetches[i] == nil else { return }
                fetches[i] = Task {
                    try Task.checkCancellation()
                    return try await synthesize(text, chosenVoice)
                }
            }
            while let self, self.generation == id, !Task.isCancelled {
                guard index < self.streamQueue.count else {
                    if self.streamEnded { break }
                    try? await Task.sleep(nanoseconds: 40_000_000)   // the AI is still writing
                    continue
                }
                // Keep the next two sentences generating at all times, so the
                // voice never waits for the server between sentences.
                let queue = self.streamQueue
                func prefetchUpcoming(_ latest: [String], includingCurrent: Bool = false) {
                    let start = includingCurrent ? index : index + 1
                    for i in start..<min(index + 3, latest.count) { fetch(i, latest[i]) }
                }
                prefetchUpcoming(queue, includingCurrent: true)
                guard let pending = fetches.removeValue(forKey: index) else { break }
                let pcm: Data
                do {
                    pcm = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
                } catch {
                    guard self.generation == id, !Task.isCancelled else { break }
                    if Self.isCancellation(error) { break }
                    Diagnostics.log("voice", ["event": "live_piece_failed", "piece": index, "error": Self.describe(error)])
                    self.errorMessage = error.localizedDescription
                    break
                }
                guard self.generation == id, !Task.isCancelled else { break }
                do {
                    let playback = try self.makePlayback(OpenRouterSpeech.wav(fromPCM: pcm, sampleRate: 24_000))
                    playback.enableRate = true
                    playback.rate = Self.playbackRate
                    playback.prepareToPlay()
                    try await self.waitForCue(generation: id)
                    guard playback.play() else { throw VoiceReplyError.invalidAudio("Bibbles") }
                    self.markStarted(id)
                    self.player = playback
                    self.isPlaying = true
                    while playback.isPlaying, self.generation == id, !Task.isCancelled {
                        // Sentences written while this one plays start generating now.
                        prefetchUpcoming(self.streamQueue)
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    guard self.generation == id, !Task.isCancelled else { break }
                    self.player = nil
                    self.isPlaying = false
                } catch {
                    guard self.generation == id, !Task.isCancelled else { break }
                    self.errorMessage = error.localizedDescription
                    Diagnostics.log("voice", ["event": "live_play_failed", "piece": index])
                    break
                }
                // Drop completed PCM immediately; only lookahead requests remain.
                self.streamQueue[index] = ""
                index += 1
            }
            guard let self, self.generation == id else { return }
            self.isActive = false
            self.isPlaying = false
            self.streamTask = nil
        }
    }
}

/// Voice previews saved on this Mac, in
/// ~/Library/Application Support/Bibbles/VoicePreviews (about 150 KB each).
enum VoicePreviewCache {
    /// The preview sentence. Changing it makes new previews (the version is
    /// part of the file name).
    static let line = "Hi, I'm Bibbles. This is how I'll sound from now on."
    private static let version = "v1"

    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bibbles/VoicePreviews", isDirectory: true)
    }

    static func file(for voice: String) -> URL? {
        let safe = voice.filter { $0.isLetter || $0.isNumber }
        guard !safe.isEmpty else { return nil }
        return folder?.appendingPathComponent("\(safe)-\(version).wav")
    }

    static func load(voice: String) -> Data? {
        guard let url = file(for: voice), let data = try? Data(contentsOf: url), data.count > 64 else { return nil }
        return data
    }

    static func save(_ wav: Data, voice: String) {
        guard let folder, let url = file(for: voice) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? wav.write(to: url, options: .atomic)
    }
}

/// The saved "thinking" lines, one WAV per line and voice, in
/// ~/Library/Application Support/Bibbles/ThinkingCues. Made once each.
enum ThinkingCueCache {
    static let lines = ["Ok, let me think first.", "Give me a moment.", "Let me look at this properly."]
    private static let version = "v1"
    private static let rotationKey = "bibbles.thinkingCueNext"

    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bibbles/ThinkingCues", isDirectory: true)
    }

    static func file(line: Int, voice: String) -> URL? {
        let safe = voice.filter { $0.isLetter || $0.isNumber }
        guard !safe.isEmpty else { return nil }
        return folder?.appendingPathComponent("\(safe)-\(line)-\(version).wav")
    }

    static func load(line: Int, voice: String) -> Data? {
        guard let url = file(line: line, voice: voice), let data = try? Data(contentsOf: url), data.count > 64 else { return nil }
        return data
    }

    static func save(_ wav: Data, line: Int, voice: String) {
        guard let folder, let url = file(line: line, voice: voice) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? wav.write(to: url, options: .atomic)
    }

    /// The line to use now; the next call uses the following one.
    static func nextIndex() -> Int {
        let current = UserDefaults.standard.integer(forKey: rotationKey) % lines.count
        UserDefaults.standard.set((current + 1) % lines.count, forKey: rotationKey)
        return current
    }
}
