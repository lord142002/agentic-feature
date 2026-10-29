import Foundation

/// Product attribution shared by local answers, AI context, and Settings.
enum BibblesIdentity {
    static let domain = "bibbles.in"
    static let attribution = "Developed by bibbles.in"
    static let spokenAttribution = "I was developed by bibbles.in."
    static let website = URL(string: "https://www.bibbles.in")!
    /// Where "Buy plan" sends people. Override with `BibblesPricingURL` in Info.plist.
    static var pricing: URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: "BibblesPricingURL") as? String,
           let url = URL(string: value), url.scheme == "https" { return url }
        return URL(string: "https://www.bibbles.in/pricing")!
    }
}
