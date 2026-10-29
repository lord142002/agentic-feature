import AppKit
import SwiftUI

struct BibblesBrandMark: View {
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.086, green: 0.078, blue: 0.157), BibblesStyle.brandNight],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(RadialGradient(colors: [BibblesStyle.accent.opacity(0.35), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.55))
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .strokeBorder(BibblesStyle.hairline, lineWidth: 0.8)
            if let logo = BibblesBrandIcon.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: size * 0.62)
            } else {
                HStack(alignment: .center, spacing: size * 0.055) {
                    ForEach(Array(zip(BibblesStyle.barHeights, BibblesStyle.barColors).enumerated()), id: \.offset) { _, pair in
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(0.84), pair.1], startPoint: .top, endPoint: .bottom))
                            .frame(width: size * 0.10, height: size * pair.0)
                            .shadow(color: pair.1.opacity(0.45), radius: size * 0.08)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Bibbles")
    }
}

enum BibblesBrandIcon {
    /// The full-colour Bibbles logo from the website, bundled with the app.
    static let logo: NSImage? = Bundle.main.url(forResource: "BrandLogo", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    /// A template image keeps the compact menu-bar mark legible in both appearances.
    static func menuBarImage() -> NSImage {
        cachedMenuBarImage
    }

    private static let cachedMenuBarImage: NSImage = {
        // The website logo as a template, so macOS tints it for light and dark menu bars.
        if let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
           let mark = NSImage(contentsOf: url), mark.size.height > 0 {
            let height: CGFloat = 17
            mark.size = NSSize(width: (mark.size.width / mark.size.height * height).rounded(), height: height)
            mark.isTemplate = true
            mark.accessibilityDescription = "Bibbles"
            return mark
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let heights: [CGFloat] = [7, 13, 10, 6]
            for (index, height) in heights.enumerated() {
                NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * 4.1 + 1, y: (18 - height) / 2,
                                           width: 2.7, height: height), xRadius: 1.35, yRadius: 1.35).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Bibbles"
        return image
    }()
}
