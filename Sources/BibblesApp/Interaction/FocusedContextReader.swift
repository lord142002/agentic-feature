import AppKit
import ApplicationServices
import Foundation

struct FocusedContextSnapshot: Equatable {
    let applicationName: String?
    let selectedText: String?
    /// Where the selection is on screen (AppKit global coordinates,
    /// bottom-left origin), when the app reports it.
    var selectionBounds: CGRect? = nil

    var hasSelectedText: Bool { selectedText?.isEmpty == false }
}

@MainActor
struct FocusedContextReader {
    func snapshot(maximumSelectedCharacters: Int = 6_000) async -> FocusedContextSnapshot {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        guard AXIsProcessTrusted() else {
            return FocusedContextSnapshot(applicationName: appName, selectedText: nil)
        }

        if let selected = accessibilitySelection(maximumCharacters: maximumSelectedCharacters) {
            return FocusedContextSnapshot(applicationName: appName, selectedText: selected.text,
                                          selectionBounds: selected.bounds)
        }

        let selected = await copiedSelection(maximumCharacters: maximumSelectedCharacters)
        return FocusedContextSnapshot(applicationName: appName, selectedText: selected)
    }

    private func accessibilitySelection(maximumCharacters: Int) -> (text: String, bounds: CGRect?)? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
        let selected = selectedValue as? String else {
            return nil
        }

        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (String(trimmed.prefix(maximumCharacters)), selectionBounds(of: focused))
    }

    /// The on-screen rectangle of the selected text, converted from the
    /// accessibility (top-left) coordinates to AppKit's bottom-left ones.
    private func selectionBounds(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue
        ) == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(boundsValue, to: AXValue.self), .cgRect, &rect),
              rect.width > 2, rect.height > 2 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let converted = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        // Ignore nonsense bounds (off every screen).
        return NSScreen.screens.contains(where: { $0.frame.intersects(converted) }) ? converted : nil
    }

    /// Chromium, Electron, canvas-based editors, and some native apps do not expose
    /// AXSelectedText. Copying is the most reliable cross-app fallback, but the
    /// user's clipboard is restored immediately after the read.
    private func copiedSelection(maximumCharacters: Int) async -> String? {
        let pasteboard = NSPasteboard.general
        let backup = ClipboardBackup(pasteboard: pasteboard)
        let originalChangeCount = pasteboard.changeCount

        guard postCopyShortcut() else { return nil }

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != originalChangeCount { break }
        }

        let didCopy = pasteboard.changeCount != originalChangeCount
        let copied = didCopy ? pasteboard.string(forType: .string) : nil
        backup.restore(to: pasteboard)

        let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumCharacters))
    }

    private func postCopyShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
private struct ClipboardBackup {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type] = data }
            }
            return values
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
    }
}
