import CryptoKit
import Foundation
import IOKit

/// A stable, anonymous ID for this Mac, sent to the Bibbles Worker as
/// `X-Bibbles-Device` so free-plan credits can be limited to one account per
/// Mac. Only a SHA-256 hash of the hardware UUID leaves the Mac; the Worker
/// hashes it again with its own secret before storing it.
enum DeviceIdentity {
    static let headerName = "X-Bibbles-Device"

    /// 64 hex characters, or nil if the hardware UUID can't be read.
    static let hashedID: String? = {
        guard let uuid = hardwareUUID(), !uuid.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("bibbles-device-v1:\(uuid)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    /// The Mac's IOPlatformUUID: the same across reinstalls and sign-outs.
    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
                                                    kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }
}
