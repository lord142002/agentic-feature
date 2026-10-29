import AppKit
import AVFoundation
import CoreGraphics

struct PermissionSnapshot {
    let accessibility: Bool
    let microphone: AVAuthorizationStatus
    let screenRecording: Bool
}

enum PermissionService {
    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: AXIsProcessTrusted(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    static func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Requests capture access on first use. Once macOS has recorded a denial,
    /// the system no longer presents the prompt, so take the user directly to
    /// the Screen Recording privacy pane instead.
    @MainActor
    static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        openScreenRecordingSettings()
        return false
    }

    @MainActor
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
