import AppKit
import Foundation
import Security

@main
enum CredentialImporterMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Deepgram API key"

        let alert = NSAlert()
        alert.messageText = "Import Bibbles Deepgram Key"
        alert.informativeText = "The key will be stored in this Mac's Keychain."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save to Keychain")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^[A-Za-z0-9]{40}$"#, options: .regularExpression) != nil else {
            showResult("Invalid key", "Expected a 40-character Deepgram credential.")
            return
        }

        do {
            try save(key)
            guard credentialExists() else { throw ImportFailure.verificationFailed }
            try "saved\n".write(toFile: "/tmp/bibbles-keychain-status", atomically: true, encoding: .utf8)
            field.stringValue = ""
            NSPasteboard.general.clearContents()
            showResult("Credential saved", "Bibbles can now access Deepgram through macOS Keychain.")
        } catch {
            showResult("Could not save credential", error.localizedDescription)
        }
    }

    private static func credentialExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.bibbles.desktop.dev",
            kSecAttrAccount as String: "deepgram-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private static func save(_ key: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.bibbles.desktop.dev",
            kSecAttrAccount as String: "deepgram-api-key"
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw ImportFailure.status(updated) }
        var addition = identity
        attributes.forEach { addition[$0.key] = $0.value }
        let added = SecItemAdd(addition as CFDictionary, nil)
        guard added == errSecSuccess else { throw ImportFailure.status(added) }
    }

    private static func showResult(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private enum ImportFailure: LocalizedError {
        case status(OSStatus)
        case verificationFailed
        var errorDescription: String? {
            switch self {
            case let .status(value): return "Keychain status \(value)."
            case .verificationFailed: return "The saved credential could not be read back."
            }
        }
    }
}
