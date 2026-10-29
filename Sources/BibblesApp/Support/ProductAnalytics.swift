import Foundation
import Combine
import PostHog

struct AnalyticsConfiguration: Equatable {
    let projectToken: String
    let host: String

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> AnalyticsConfiguration? {
        let token = (environment["BIBBLES_POSTHOG_PROJECT_TOKEN"]
            ?? info["BibblesPostHogProjectToken"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (environment["BIBBLES_POSTHOG_HOST"]
            ?? info["BibblesPostHogHost"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept only a public project token and an explicit HTTPS ingestion origin.
        guard token.hasPrefix("phc_"), token.count > 4,
              let url = URL(string: host), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return AnalyticsConfiguration(projectToken: token, host: host)
    }
}

enum AnalyticsEvent: String, CaseIterable {
    case signedUp = "user_signed_up"
    case loggedIn = "user_logged_in"
    case chatResponseReceived = "chat_response_received"
    case dictationCompleted = "dictation_completed"
    case screenHelpCompleted = "screen_help_completed"
    case tutorialCompleted = "tutorial_completed"
}

/// Only app-owned names, never window titles, conversation names, URLs or file names.
enum AnalyticsScreen: Equatable {
    case chat, plans
    case settings(SettingsSection)

    var name: String {
        switch self {
        case .chat: return "chat"
        case .plans: return "plans"
        case .settings(let section): return "settings_" + section.rawValue
        }
    }
}

enum AnalyticsAuthMethod: String { case email, google, apple, emailConfirmation = "email_confirmation" }
enum AnalyticsChatMode: String { case ask, search, write }

@MainActor
protocol AnalyticsClient: AnyObject {
    func start(_ configuration: AnalyticsConfiguration)
    func setCollectionEnabled(_ enabled: Bool)
    func identify(_ userID: String)
    func reset()
    func screen(_ name: String)
    func capture(_ event: AnalyticsEvent, properties: [String: String])
}

@MainActor
final class PostHogAnalyticsClient: AnalyticsClient {
    private let sdk = PostHogSDK.shared

    func start(_ configuration: AnalyticsConfiguration) {
        sdk.setup(Self.sdkConfiguration(configuration))
    }

    static func sdkConfiguration(_ configuration: AnalyticsConfiguration) -> PostHogConfig {
        let config = PostHogConfig(projectToken: configuration.projectToken, host: configuration.host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.setDefaultPersonProperties = false
        config.disableGeoIp = true
        config.errorTrackingConfig.autoCapture = false
        config.personProfiles = .identifiedOnly
        // Session replay and element autocapture are unavailable on native macOS.
        // No replay, surveys, logging or exception capture is enabled here.
        config.setBeforeSend { event in
            guard AnalyticsEvent(rawValue: event.event) != nil
                || event.event == "$screen" || event.event == "$identify" else { return nil }
            let allowed: Set<String> = ["$anon_distinct_id", "$is_identified", "$process_person_profile",
                "$lib", "$lib_version", "$screen_name", "$session_id", "$window_id",
                "$app_version", "$app_build", "$geoip_disable", "mode", "method"]
            event.properties = event.properties.filter { allowed.contains($0.key) }
            return event
        }
        return config
    }

    func setCollectionEnabled(_ enabled: Bool) { if enabled { sdk.optIn() } else { sdk.optOut() } }
    func identify(_ userID: String) { sdk.identify(userID) }
    func reset() { sdk.reset() }
    func screen(_ name: String) { sdk.screen(name) }
    func capture(_ event: AnalyticsEvent, properties: [String: String]) {
        sdk.capture(event.rawValue, properties: properties)
    }
}

/// Consent is stored locally. Nothing is initialized, queued or backfilled before consent.
@MainActor
final class ProductAnalytics: ObservableObject {
    static let shared = ProductAnalytics(client: PostHogAnalyticsClient())
    static let consentKey = "bibbles.analytics.consent.v1"
    private static let pendingSignupKey = "bibbles.analytics.pendingSignup.v1"
    @Published private(set) var hasConsent: Bool
    let isConfigured: Bool

    private let configuration: AnalyticsConfiguration?
    private let client: AnalyticsClient
    private let defaults: UserDefaults
    private var started = false
    private var userID: String?
    private var identifiedID: String?
    private var visibleScreen: AnalyticsScreen?
    private var capturedScreen: AnalyticsScreen?

    init(configuration: AnalyticsConfiguration? = AnalyticsConfiguration.load(),
         defaults: UserDefaults = .standard, client: AnalyticsClient) {
        self.configuration = configuration
        self.defaults = defaults
        self.client = client
        isConfigured = configuration != nil
        hasConsent = defaults.bool(forKey: Self.consentKey)
        if !hasConsent { defaults.removeObject(forKey: Self.pendingSignupKey) }
    }

    func start(userID: String?) {
        setUserID(userID)
        activateIfAllowed()
    }

    func setConsent(_ allowed: Bool) {
        guard hasConsent != allowed else { return }
        hasConsent = allowed
        defaults.set(allowed, forKey: Self.consentKey)
        if !allowed { defaults.removeObject(forKey: Self.pendingSignupKey) }
        if allowed {
            activateIfAllowed()
        } else if started {
            client.setCollectionEnabled(false)
            client.reset()
            // reset clears SDK preferences; preserve the explicit opt-out afterwards.
            client.setCollectionEnabled(false)
            identifiedID = nil
            capturedScreen = nil
        }
    }

    func setUserID(_ id: String?) {
        guard userID != id else { return }
        userID = id
        guard started, hasConsent else { return }
        if identifiedID != nil { client.reset() }
        identifiedID = nil
        identifyCurrentUser()
        capturedScreen = nil
    }

    func authenticationSucceeded(userID: String, signedUp: Bool, method: AnalyticsAuthMethod) {
        setUserID(userID)
        track(signedUp ? .signedUp : .loggedIn, method: method)
    }

    func awaitingSignupVerification(userID: String) {
        guard hasConsent, isConfigured else { return }
        defaults.set(userID, forKey: Self.pendingSignupKey)
    }

    /// Consume once, whether completion arrives through OTP, a callback or auth restoration.
    func signupVerified(userID: String) {
        guard defaults.string(forKey: Self.pendingSignupKey) == userID else { return }
        defaults.removeObject(forKey: Self.pendingSignupKey)
        authenticationSucceeded(userID: userID, signedUp: true, method: .emailConfirmation)
    }

    func screen(_ screen: AnalyticsScreen) {
        visibleScreen = screen
        guard started, hasConsent, capturedScreen != screen else { return }
        client.screen(screen.name)
        capturedScreen = screen
    }

    func leaveScreen(_ screen: AnalyticsScreen) {
        if visibleScreen == screen { visibleScreen = nil; capturedScreen = nil }
    }

    func track(_ event: AnalyticsEvent, mode: AnalyticsChatMode? = nil, method: AnalyticsAuthMethod? = nil) {
        guard started, hasConsent else { return }
        var properties: [String: String] = [:]
        if let mode { properties["mode"] = mode.rawValue }
        if let method { properties["method"] = method.rawValue }
        client.capture(event, properties: properties)
    }

    private func activateIfAllowed() {
        guard hasConsent, let configuration else { return }
        if !started {
            client.start(configuration)
            started = true
            // Discard a previous run's identity before any app event is sent.
            client.reset()
        }
        client.setCollectionEnabled(true)
        identifyCurrentUser()
        if let visibleScreen { screen(visibleScreen) }
    }

    private func identifyCurrentUser() {
        guard let userID, identifiedID != userID else { return }
        client.identify(userID)
        identifiedID = userID
    }
}
