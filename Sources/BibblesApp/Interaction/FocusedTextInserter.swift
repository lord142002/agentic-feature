import AppKit
import ApplicationServices
import Foundation

enum FocusedTextInsertionError: LocalizedError {
    case accessibilityPermissionRequired
    case noFocusedElement
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Allow Bibbles in System Settings → Privacy & Security → Accessibility, then reopen Bibbles and try dictation again."
        case .noFocusedElement:
            return "Click the text field in the app where you want to dictate, then hold Function + Control and speak."
        case .insertionFailed:
            return "Bibbles could not insert text into the focused app."
        }
    }
}

@MainActor
struct FocusedTextInserter {
    func insert(_ text: String) throws {
        // Dictating into Bibbles' own chat box or type box.
        if Self.bibblesIsFrontmost {
            guard Self.insertIntoOwnTextBox(text) else { throw FocusedTextInsertionError.noFocusedElement }
            return
        }
        guard AXIsProcessTrusted() else {
            throw FocusedTextInsertionError.accessibilityPermissionRequired
        }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            throw FocusedTextInsertionError.noFocusedElement
        }

        if let focused = focusedElement(for: frontmostApp.processIdentifier) {
            var settable = DarwinBoolean(false)
            let settableResult = AXUIElementIsAttributeSettable(
                focused,
                kAXSelectedTextAttribute as CFString,
                &settable
            )
            if settableResult == .success, settable.boolValue,
               AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextAttribute as CFString,
                text as CFString
               ) == .success {
                return
            }
        }

        // Browser and rich-text editors may receive keyboard input even when
        // they do not expose an AX focused element or settable selected text.
        guard postUnicode(text) else {
            throw FocusedTextInsertionError.insertionFailed
        }
    }

    typealias ClipboardSnapshot = [[(NSPasteboard.PasteboardType, Data)]]

    /// Inserts text into the frontmost app by pasting it. Pasting keeps line
    /// breaks in Mail, Gmail, Notes, Slack and other rich-text editors. By
    /// default the user's clipboard is restored afterwards.
    func paste(_ text: String, restoringClipboard: Bool = true) throws {
        if Self.bibblesIsFrontmost {
            guard Self.insertIntoOwnTextBox(text) else { throw FocusedTextInsertionError.noFocusedElement }
            return
        }
        guard AXIsProcessTrusted() else {
            throw FocusedTextInsertionError.accessibilityPermissionRequired
        }
        guard NSWorkspace.shared.frontmostApplication != nil else {
            throw FocusedTextInsertionError.noFocusedElement
        }
        let saved = restoringClipboard ? snapshotClipboard() : nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount

        guard postKey(9, flags: .maskCommand) else {
            throw FocusedTextInsertionError.insertionFailed
        }

        if let saved {
            // Give the target app time to read the clipboard before restoring it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard pasteboard.changeCount == changeCount else { return }
                Self.restore(saved)
            }
        }
    }

    /// Selects `text` inside the focused text box of the frontmost app, so the
    /// next paste replaces it. Used to swap out something Bibbles wrote
    /// earlier. Only a complete exact or whitespace/quote-normalized match
    /// is safe to replace; shared opening/closing words are not enough.
    func selectText(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement(for: app.processIdentifier) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let full = value as? String else { return false }
        guard var range = Self.range(of: text, in: full) else { return false }
        guard let axRange = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
    }

    /// `selectText`, but first asks Chromium browsers and Electron apps to
    /// expose their page text (they hide it from Accessibility until an app
    /// asks), and tries again once after they have had a moment to do so.
    func selectTextAllowingAccessibilityWarmUp(_ text: String) async -> Bool {
        guard !Task.isCancelled, let app = NSWorkspace.shared.frontmostApplication else { return false }
        let wasEnabled = Self.enableFullAccessibility(for: app)
        if !wasEnabled { try? await Task.sleep(nanoseconds: 350_000_000) }
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        if selectText(text) { return true }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        return selectText(text)
    }

    /// Apps Bibbles already asked, so the warm-up wait happens once per app.
    private static var accessibilityRequested: Set<pid_t> = []

    /// Chromium-based browsers.
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.chromium.Chromium"
    ]

    /// Asks the app to build its full Accessibility tree (Chromium/Electron
    /// read `AXManualAccessibility`; Chromium browsers also
    /// `AXEnhancedUserInterface`). Returns true if it had already been asked.
    @discardableResult
    static func enableFullAccessibility(for app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted(), !app.isTerminated else { return true }
        if accessibilityRequested.contains(app.processIdentifier) { return true }
        accessibilityRequested.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundle = app.bundleIdentifier, chromiumBrowsers.contains(bundle) {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return false
    }

    /// Where `needle` sits in `haystack` (UTF-16 offsets, as Accessibility uses).
    nonisolated static func range(of needle: String, in haystack: String) -> CFRange? {
        if let exact = exactRange(of: needle, in: haystack) { return exact }
        // Editors (Gmail, Notes, Word…) change line breaks, non-breaking
        // spaces and quote marks. Compare with those smoothed out, then map
        // the match back to the editor's real text.
        let (normalizedHaystack, map) = normalizedUTF16(haystack)
        let (normalizedNeedle, _) = normalizedUTF16(needle)
        guard let found = exactRange(of: normalizedNeedle, in: normalizedHaystack),
              found.length > 0, found.location + found.length <= map.count else { return nil }
        let start = map[found.location].start
        let end = map[found.location + found.length - 1].end
        return CFRange(location: start, length: end - start)
    }

    /// Exact search only; normalization is performed by the caller on failure.
    nonisolated private static func exactRange(of needle: String, in haystack: String) -> CFRange? {
        let whole = haystack as NSString
        let target = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let exact = whole.range(of: target)
        guard exact.location != NSNotFound else { return nil }
        return CFRange(location: exact.location, length: exact.length)
    }

    /// The text as UTF-16 with whitespace runs collapsed to one space,
    /// zero-width characters dropped and curly quotes straightened, plus,
    /// for each kept unit, its range in the original text.
    nonisolated static func normalizedUTF16(_ text: String) -> (String, [(start: Int, end: Int)]) {
        let units = Array(text.utf16)
        var output: [UInt16] = []
        var map: [(start: Int, end: Int)] = []
        var index = 0
        func isSpace(_ unit: UInt16) -> Bool {
            [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xA0, 0x2028, 0x2029, 0x202F, 0x2007].contains(unit)
        }
        while index < units.count {
            let unit = units[index]
            if [0x200B, 0x200C, 0x200D, 0xFEFF, 0x00AD].contains(unit) { index += 1; continue }
            if isSpace(unit) {
                let start = index
                while index < units.count, isSpace(units[index]) || [0x200B, 0xFEFF].contains(units[index]) { index += 1 }
                output.append(0x20)
                map.append((start, index))
                continue
            }
            var mapped = unit
            switch unit {
            case 0x2018, 0x2019, 0x201B, 0x2032: mapped = 0x27
            case 0x201C, 0x201D, 0x201F, 0x2033: mapped = 0x22
            case 0x2013, 0x2014: mapped = 0x2D
            default: break
            }
            output.append(mapped)
            map.append((index, index + 1))
            index += 1
        }
        return (String(utf16CodeUnits: output, count: output.count), map)
    }

    /// True when Bibbles itself (chat window, type box, settings) is in front.
    static var bibblesIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || NSApp.isActive
    }

    /// Types into the text box that has the cursor in one of Bibbles' own
    /// windows (macOS Accessibility can't be used on our own app).
    static func insertIntoOwnTextBox(_ text: String) -> Bool {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            + NSApp.windows.filter { $0.isVisible }
        for window in windows {
            guard let editor = window.firstResponder as? NSTextView, editor.isEditable else { continue }
            // Add a space between earlier text and the dictated words.
            let range = editor.selectedRange()
            let before = range.location > 0
                ? (editor.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1))
                : ""
            let needsSpace = !before.isEmpty && before.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            editor.insertText(needsSpace ? " " + text : text, replacementRange: range)
            return true
        }
        return false
    }

    /// Presses Command-A in the frontmost app (selects the focused box's text).
    func pressSelectAll() {
        _ = postKey(0, flags: .maskCommand)
    }

    nonisolated func snapshotClipboard() -> ClipboardSnapshot {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    nonisolated func restoreClipboard(_ saved: ClipboardSnapshot) {
        Self.restore(saved)
    }

    private nonisolated static func restore(_ saved: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { entries in
            let item = NSPasteboardItem()
            entries.forEach { item.setData($0.1, forType: $0.0) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    func beginLiveSession() -> LiveFocusedTextSession? {
        guard AXIsProcessTrusted(),
              let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement(for: frontmostApp.processIdentifier) else { return nil }
        var selectedTextSettable = DarwinBoolean(false)
        var selectedRangeSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success, selectedTextSettable.boolValue,
        AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeSettable
        ) == .success, selectedRangeSettable.boolValue else { return nil }

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        var selectedRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &selectedRange) else {
            return nil
        }
        guard selectedRange.location >= 0, selectedRange.length >= 0 else { return nil }
        var selectedText: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        ) == .success,
        let originalSelection = selectedText as? String else { return nil }
        return LiveFocusedTextSession(
            element: element,
            insertionLocation: selectedRange.location,
            originalSelection: originalSelection,
            originalSelectionLength: selectedRange.length
        )
    }

    private func focusedElement(for processID: pid_t) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let element = focusedElement(in: system) { return element }
        return focusedElement(in: AXUIElementCreateApplication(processID))
    }

    private func focusedElement(in parent: AXUIElement) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            parent,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
    }

    private func postUnicode(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let units = Array(text.utf16)
        guard !units.isEmpty else { return true }

        for chunkStart in stride(from: 0, to: units.count, by: 20) {
            let chunkEnd = min(chunkStart + 20, units.count)
            let chunk = Array(units[chunkStart..<chunkEnd])
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }
}

final class LiveFocusedTextSession {
    enum FinishResult {
        case inserted
        case failedWithDraft
        case failedWithoutDraft
    }

    private let element: AXUIElement
    private let insertionLocation: Int
    private let originalSelection: String
    private var insertedLength: Int
    private var hasWrittenDraft = false
    private var active = true

    init(
        element: AXUIElement,
        insertionLocation: Int,
        originalSelection: String,
        originalSelectionLength: Int
    ) {
        self.element = element
        self.insertionLocation = insertionLocation
        self.originalSelection = originalSelection
        self.insertedLength = originalSelectionLength
    }

    @discardableResult
    func replaceDraft(with text: String) -> Bool {
        guard active else { return false }
        var range = CFRange(location: insertionLocation, length: insertedLength)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                value
              ) == .success,
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
              ) == .success else { return false }
        insertedLength = (text as NSString).length
        hasWrittenDraft = true
        return true
    }

    @discardableResult
    func finish(with text: String) -> FinishResult {
        guard active else { return hasWrittenDraft ? .failedWithDraft : .failedWithoutDraft }
        let finalized = replaceDraft(with: text)
        active = false
        if finalized { return .inserted }
        return hasWrittenDraft ? .failedWithDraft : .failedWithoutDraft
    }

    func cancel() {
        guard active else { return }
        var range = CFRange(location: insertionLocation, length: insertedLength)
        if let value = AXValueCreate(.cfRange, &range) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                originalSelection as CFString
            )
        }
        active = false
    }
}
