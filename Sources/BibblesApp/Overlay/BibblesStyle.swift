import AppKit
import SwiftUI

/// Colours from the Bibbles website (bibbles.in): a deep night background,
/// soft lavender text and a violet / periwinkle accent.
enum BibblesStyle {
    /// --accent #A18CFF
    static let accent = Color(red: 0.631, green: 0.549, blue: 1.0)
    /// --accent-2 #6F8DFF
    static let accentSecondary = Color(red: 0.435, green: 0.553, blue: 1.0)
    /// Accent for text and icons: bright on dark backgrounds, deeper on light
    /// ones so it stays readable.
    static let accentDeep = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.765, green: 0.714, blue: 1, alpha: 1)   // #C3B6FF
            : NSColor(srgbRed: 0.373, green: 0.290, blue: 0.839, alpha: 1) // #5F4AD6
    })
    /// --surface #0D0C16
    static let brandBackground = Color(red: 0.051, green: 0.047, blue: 0.086)
    /// --bg #06060C
    static let brandNight = Color(red: 0.024, green: 0.024, blue: 0.047)
    static let barColors: [Color] = [
        Color(red: 0.765, green: 0.714, blue: 1.0),
        Color(red: 0.631, green: 0.549, blue: 1.0),
        Color(red: 0.541, green: 0.549, blue: 1.0),
        Color(red: 0.435, green: 0.553, blue: 1.0)
    ]
    static let barHeights: [CGFloat] = [0.27, 0.48, 0.38, 0.23]
    static let ink = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// --line rgba(180,170,255,.13), a lavender hairline.
    static let hairline = Color(red: 0.706, green: 0.667, blue: 1.0).opacity(0.22)
}
