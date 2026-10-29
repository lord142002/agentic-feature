import Foundation

/// A small local log of what Bibbles decided (counts, timings and error
/// kinds only: never questions, answers, screen text or keys), so a bug that
/// happens "sometimes" can be traced. Kept on this Mac only, last ~300 lines:
/// ~/Library/Application Support/Bibbles/diagnostics.log
enum Diagnostics {
    private static let queue = DispatchQueue(label: "bibbles.diagnostics")
    static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bibbles/diagnostics.log")
    }

    static func log(_ area: String, _ fields: [String: Any]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = fields.keys.sorted().map { "\($0)=\(fields[$0].map { "\($0)" } ?? "nil")" }.joined(separator: " ")
        let line = "\(stamp) [\(area)] \(body)\n"
        queue.async {
            guard let file else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            lines.append(String(line.dropLast()))
            if lines.count > 300 { lines.removeFirst(lines.count - 300) }
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
