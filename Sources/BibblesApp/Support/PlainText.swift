import Foundation

/// Turns an AI answer into clean, plain prose before Bibbles types or copies
/// it into another app. Removes Markdown syntax (**bold**, *italics*, # titles,
/// `code`, - bullets, > quotes, [links](url), --- rules) and replaces em/en
/// dashes used as punctuation with commas, so Notes, Mail, Messages and other
/// apps receive ordinary written text in any language.
enum PlainText {
    /// Apps where the text is likely code or a shell command: left untouched.
    static let codeAppBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.warp.Warp-Stable", "dev.zed.Zed", "com.sublimetext.4", "com.panic.Nova",
        "net.kovidgoyal.kitty", "io.alacritty", "com.mitchellh.ghostty", "com.exafunction.windsurf"
    ]

    static func isCodeApp(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if codeAppBundleIDs.contains(bundleID) { return true }
        return bundleID.hasPrefix("com.jetbrains.")
    }

    /// Cleans `text` for the app with `bundleID` (unchanged for code apps).
    static func clean(_ text: String, forAppBundleID bundleID: String?) -> String {
        if isCodeApp(bundleID: bundleID) || looksLikeCode(text) { return text }
        return clean(text)
    }

    /// True when the text reads like source code or shell commands (for
    /// example code typed into a browser editor), which must stay exact.
    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let codeStarts = ["#include", "import ", "def ", "class ", "public ", "private ", "func ", "fn ",
                          "const ", "let ", "var ", "return ", "for (", "if (", "while (", "#!/", "$ ", "sudo "]
        var score = 0
        for line in lines where !line.isEmpty {
            if codeStarts.contains(where: { line.hasPrefix($0) }) { score += 1 }
            if line.hasSuffix(";") || line.hasSuffix("{") || line == "}" || line.hasSuffix("):") { score += 1 }
        }
        return score >= 2
    }

    static func clean(_ text: String) -> String {
        var lines: [String] = []
        var inFence = false
        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // Code fences: drop the ``` markers, keep the code lines as they are.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { lines.append(rawLine); continue }
            lines.append(cleanLine(rawLine))
        }
        var result = lines.joined(separator: "\n")
        // No more than one blank line in a row.
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanLine(_ line: String) -> String {
        var s = line
        let leading = String(s.prefix { $0 == " " || $0 == "\t" })
        s = String(s.dropFirst(leading.count))

        // Horizontal rules (---, ***, ___) become a blank line.
        if s.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { return "" }
        // Headings: "## Title" -> "Title".
        s = s.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        // Block quotes.
        s = s.replacingOccurrences(of: #"^(>\s?)+"#, with: "", options: .regularExpression)
        // Bullets: "- item", "* item", "+ item", "• item" -> "item".
        s = s.replacingOccurrences(of: #"^[-*+•]\s+"#, with: "", options: .regularExpression)
        // Task-list boxes left behind: "[ ] item" / "[x] item".
        s = s.replacingOccurrences(of: #"^\[[ xX]\]\s+"#, with: "", options: .regularExpression)

        s = cleanInline(s)
        // Bullets nested under other bullets keep no indent; numbered lists keep theirs.
        return s
    }

    private static func cleanInline(_ input: String) -> String {
        var s = input
        // Images and links: ![alt](url) -> alt, [text](url) -> text (url).
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Bold / italic / strikethrough markers around text.
        s = s.replacingOccurrences(of: #"\*\*\*(.+?)\*\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w_])__(.+?)__(?![\w_])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
        // Inline code: `text` -> text.
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // Any stray bold markers that were not paired.
        s = s.replacingOccurrences(of: "**", with: "")
        // Em/en dashes used as punctuation: "word — word" -> "word, word".
        s = s.replacingOccurrences(of: #"\s+[—–]\s+"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<=\w)—(?=\w)"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*,"#, with: ",", options: .regularExpression)
        // Tidy spaces left behind.
        s = s.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Instruction added to AI prompts so answers arrive as clean prose.
    static let promptRule = " Write in clean, plain prose in the user's language, as a careful human writer would. Never use Markdown or symbols for formatting: no asterisks, no pound signs, no backticks, no underscores for emphasis, no dash or asterisk bullet points, and no em dashes (use commas, periods or the word 'and' instead). When several points are needed, write short paragraphs or full sentences; if a list is truly necessary, use '1.', '2.', '3.' at the start of each line."
}
