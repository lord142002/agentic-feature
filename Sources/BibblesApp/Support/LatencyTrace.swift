import Foundation

struct LatencySpan: Equatable {
    let name: String
    let startedAt: ContinuousClock.Instant
    var endedAt: ContinuousClock.Instant?
}

@MainActor
final class LatencyRecorder {
    private(set) var spans: [String: LatencySpan] = [:]

    func begin(_ name: String) {
        spans[name] = LatencySpan(name: name, startedAt: .now, endedAt: nil)
    }

    func end(_ name: String) {
        guard var span = spans[name] else { return }
        guard span.endedAt == nil else { return }
        span.endedAt = .now
        spans[name] = span
    }

    /// Timing logs are for development only: written when BIBBLES_LATENCY_LOG=1.
    static var isLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["BIBBLES_LATENCY_LOG"] == "1"
    }

    func appendCompletedSample(to url: URL = URL(fileURLWithPath: "/tmp/bibbles-latency.jsonl")) {
        guard Self.isLoggingEnabled else { return }
        var durations: [String: Double] = [:]
        for (name, span) in spans {
            guard let endedAt = span.endedAt else { continue }
            let components = span.startedAt.duration(to: endedAt).components
            durations[name] = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "milliseconds": durations
        ]
        guard !durations.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var line = data
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch { return }
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    func clear() {
        spans.removeAll(keepingCapacity: true)
    }
}
