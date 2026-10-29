import XCTest
@testable import BibblesApp

@MainActor
final class ProductAnalyticsTests: XCTestCase {
    private let configuration = AnalyticsConfiguration(projectToken: "phc_test_project", host: "https://us.i.posthog.com")

    private func make(consent: Bool = false, configured: Bool = true) -> (ProductAnalytics, RecordingAnalyticsClient, UserDefaults) {
        let defaults = UserDefaults(suiteName: "bibbles.analytics.tests.\(UUID())")!
        defaults.set(consent, forKey: ProductAnalytics.consentKey)
        let client = RecordingAnalyticsClient()
        return (ProductAnalytics(configuration: configured ? configuration : nil,
                                 defaults: defaults, client: client), client, defaults)
    }

    func testMissingConfigurationIsANoopEvenWithConsent() {
        let (analytics, client, _) = make(consent: true, configured: false)
        analytics.start(userID: "user-a")
        analytics.screen(.chat)
        analytics.track(.dictationCompleted)
        XCTAssertTrue(client.calls.isEmpty)
    }

    func testNoSDKOrBackfilledEventsBeforeConsent() {
        let (analytics, client, defaults) = make()
        analytics.start(userID: "user-a")
        analytics.authenticationSucceeded(userID: "user-a", signedUp: true, method: .email)
        analytics.track(.dictationCompleted)
        analytics.screen(.chat)
        XCTAssertTrue(client.calls.isEmpty)
        analytics.setConsent(true)
        XCTAssertTrue(defaults.bool(forKey: ProductAnalytics.consentKey))
        XCTAssertEqual(client.calls, ["start", "reset", "enabled:true", "identify:user-a", "screen:chat"])
        XCTAssertTrue(client.events.isEmpty)
    }

    func testRestoredUserIsIdentifiedOnceWithoutFakeLogin() {
        let (analytics, client, _) = make(consent: true)
        analytics.start(userID: "user-a")
        analytics.start(userID: "user-a")
        analytics.setUserID("user-a")
        XCTAssertEqual(client.calls.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(client.calls.filter { $0 == "identify:user-a" }.count, 1)
        XCTAssertTrue(client.events.isEmpty)
    }

    func testLogoutAndDirectAccountSwitchResetBeforeNextEvent() {
        let (analytics, client, _) = make(consent: true)
        analytics.start(userID: "user-a")
        client.calls = []
        analytics.setUserID("user-b")
        XCTAssertEqual(client.calls, ["reset", "identify:user-b"])
        client.calls = []
        analytics.setUserID(nil)
        analytics.setUserID(nil)
        XCTAssertEqual(client.calls, ["reset"])
    }

    func testRevocationStopsCaptureAndReconsentDoesNotReinitialize() {
        let (analytics, client, _) = make(consent: true)
        analytics.start(userID: "user-a")
        analytics.setConsent(false)
        client.calls = []
        analytics.track(.screenHelpCompleted)
        analytics.screen(.plans)
        analytics.setUserID("user-b")
        XCTAssertTrue(client.calls.isEmpty)
        analytics.setConsent(true)
        XCTAssertEqual(client.calls, ["enabled:true", "identify:user-b", "screen:plans"])
    }

    func testNativeScreenViewsDeduplicateAndTrackNavigationAndReopening() {
        let (analytics, client, _) = make(consent: true)
        analytics.start(userID: nil)
        analytics.screen(.settings(.general))
        analytics.screen(.settings(.general))
        analytics.screen(.settings(.account))
        analytics.leaveScreen(.settings(.account))
        analytics.screen(.settings(.account))
        XCTAssertEqual(client.calls.filter { $0.hasPrefix("screen:") },
                       ["screen:settings_general", "screen:settings_account", "screen:settings_account"])
    }

    func testSuccessEventsHaveOnlyFixedProperties() {
        let (analytics, client, _) = make(consent: true)
        analytics.start(userID: nil)
        analytics.authenticationSucceeded(userID: "internal-uuid", signedUp: true, method: .emailConfirmation)
        analytics.authenticationSucceeded(userID: "internal-uuid", signedUp: false, method: .google)
        analytics.track(.chatResponseReceived, mode: .search)
        analytics.track(.dictationCompleted)
        XCTAssertEqual(client.events.map(\.0), [.signedUp, .loggedIn, .chatResponseReceived, .dictationCompleted])
        XCTAssertEqual(client.events.map(\.1), [["method": "email_confirmation"], ["method": "google"], ["mode": "search"], [:]])
    }

    func testConfigurationRequiresProjectTokenAndExplicitHTTPSOrigin() {
        XCTAssertNil(AnalyticsConfiguration.load(environment: [:], info: [:]))
        for token in ["", "phx_personal_key", "phs_secret_key", "<ph_project_token>"] {
            XCTAssertNil(AnalyticsConfiguration.load(environment: ["BIBBLES_POSTHOG_PROJECT_TOKEN": token,
                "BIBBLES_POSTHOG_HOST": "https://us.i.posthog.com"], info: [:]))
        }
        for host in ["http://example.com", "https://user:secret@example.com", "https://example.com/path?token=secret"] {
            XCTAssertNil(AnalyticsConfiguration.load(environment: ["BIBBLES_POSTHOG_PROJECT_TOKEN": "phc_test",
                "BIBBLES_POSTHOG_HOST": host], info: [:]))
        }
        XCTAssertEqual(AnalyticsConfiguration.load(environment: [:], info: [
            "BibblesPostHogProjectToken": configuration.projectToken, "BibblesPostHogHost": configuration.host]), configuration)
    }

    func testSDKAutomaticCollectionIsDisabled() {
        let config = PostHogAnalyticsClient.sdkConfiguration(configuration)
        XCTAssertFalse(config.captureScreenViews)
        XCTAssertFalse(config.captureApplicationLifecycleEvents)
        XCTAssertFalse(config.enableSwizzling)
        XCTAssertFalse(config.preloadFeatureFlags)
        XCTAssertFalse(config.sendFeatureFlagEvent)
        XCTAssertFalse(config.setDefaultPersonProperties)
        XCTAssertFalse(config.errorTrackingConfig.autoCapture)
        XCTAssertTrue(config.disableGeoIp)
    }

    func testVerifiedSignupIsConsumedOnceAndRevocationDropsPendingSignup() {
        let (analytics, client, _) = make(consent: true)
        analytics.start(userID: nil)
        analytics.awaitingSignupVerification(userID: "user-a")
        analytics.signupVerified(userID: "user-a")
        analytics.signupVerified(userID: "user-a")
        XCTAssertEqual(client.events.map(\.0), [.signedUp])
        analytics.awaitingSignupVerification(userID: "user-b")
        analytics.setConsent(false)
        analytics.setConsent(true)
        analytics.signupVerified(userID: "user-b")
        XCTAssertEqual(client.events.map(\.0), [.signedUp])
    }

    func testSignupStartedWithoutConsentIsNotBackfilledAfterOptIn() {
        let (analytics, client, _) = make()
        analytics.start(userID: nil)
        analytics.awaitingSignupVerification(userID: "user-a")
        analytics.setConsent(true)
        analytics.signupVerified(userID: "user-a")
        XCTAssertTrue(client.events.isEmpty)
    }
}

@MainActor
private final class RecordingAnalyticsClient: AnalyticsClient {
    var calls: [String] = []
    var events: [(AnalyticsEvent, [String: String])] = []
    func start(_ configuration: AnalyticsConfiguration) { calls.append("start") }
    func setCollectionEnabled(_ enabled: Bool) { calls.append("enabled:\(enabled)") }
    func identify(_ userID: String) { calls.append("identify:\(userID)") }
    func reset() { calls.append("reset") }
    func screen(_ name: String) { calls.append("screen:\(name)") }
    func capture(_ event: AnalyticsEvent, properties: [String: String]) {
        events.append((event, properties))
        calls.append("event:\(event.rawValue)")
    }
}
