import AppKit
import Auth
import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// One account across Google, Apple, and email sign-in. The Auth SDK keeps the
/// refreshable session in the macOS Keychain; API provider keys remain separate.
@MainActor
final class AccountSession: ObservableObject {
    static let shared = AccountSession()
    static let callbackURL = URL(string: "bibbles-auth://callback")!

    @Published private(set) var email: String? {
        didSet { refreshUserID() }
    }
    /// The signed-in Supabase user's id (lowercase UUID). Local data such as
    /// chat history is kept separately for each id, so a different person
    /// signing in on this Mac never sees someone else's conversations.
    @Published private(set) var userID: String? {
        didSet { ProductAnalytics.shared.setUserID(userID) }
    }
    /// Accounts deleted while this app was running; their local data is erased.
    private(set) var deletedUserIDs: Set<String> = []

    private func refreshUserID() {
        guard email != nil else {
            if userID != nil { userID = nil }
            return
        }
        // Keep the known id while a sign-in finishes; never invent one.
        if let id = client?.currentSession?.user.id.uuidString.lowercased(), id != userID { userID = id }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsNewPassword = false
    /// Set while the user is entering an emailed code (sign-up or password reset).
    @Published private(set) var pendingVerification: PendingVerification?
    /// Set when sign-up hits an address that is already registered, so the UI flips to Sign in.
    @Published private(set) var switchToSignIn = false

    struct PendingVerification: Equatable {
        enum Kind: Equatable { case signup, recovery }
        enum Stage: Equatable { case code, newPassword }
        let email: String
        let kind: Kind
        var stage: Stage = .code
    }
    @Published private(set) var isConfigured = false
    @Published private(set) var googleEnabled = false
    @Published private(set) var appleEnabled = false
    @Published private(set) var emailEnabled = true
    @Published private(set) var providerStatus = "Checking sign-in methods…"
    @Published private(set) var workerUsage: WorkerUsageSnapshot?
    @Published private(set) var usageError: String?
    @Published private(set) var usageIsRefreshing = false
    /// Paid-plan expiry, from the Worker when it sends it, else read from Supabase.
    @Published private(set) var planEntitlement: PlanEntitlement?
    /// The Dodo subscription as the billing Worker recorded it (nil until loaded or unavailable).
    @Published private(set) var billingStatus: BillingStatus?
    /// True while a checkout/portal link is being prepared or a payment is being confirmed.
    @Published private(set) var billingBusy = false
    @Published private(set) var awaitingPayment = false

    /// The plan to show: a confirmed paid subscription wins over the usage plan.
    var effectivePlanName: String? {
        if let billing = billingStatus, billing.hasAccess { return billing.plan }
        return workerUsage?.plan ?? planEntitlement?.plan
    }

    /// Supabase tables checked (in order) for the signed-in user's plan expiry.
    /// Each is queried with the user's own token, so RLS must allow reading own rows.
    static let entitlementTables: [(table: String, userColumn: String)] = [
        ("subscriptions", "user_id"), ("user_subscriptions", "user_id"), ("user_plans", "user_id"),
        ("profiles", "id"), ("profiles", "user_id"), ("users", "id"), ("users", "user_id"),
        ("accounts", "user_id"), ("plans", "user_id")
    ]

    static var nativeAppleSignInEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "BibblesAppleSignInEnabled") as? Bool == true
    }

    private var client: AuthClient?
    private var authEvents: Task<Void, Never>?
    private var usageRefreshID = UUID()
    private var paymentWatch: Task<Void, Never>?
    private var projectURL: URL?
    private var projectKey: String?

    private init() {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let url = env["BIBBLES_SUPABASE_URL"] ?? info["BibblesSupabaseURL"] as? String
            ?? UserDefaults.standard.string(forKey: "bibbles.supabaseURL")
        let key = env["BIBBLES_SUPABASE_PUBLISHABLE_KEY"] ?? info["BibblesSupabasePublishableKey"] as? String
            ?? UserDefaults.standard.string(forKey: "bibbles.supabasePublishableKey")
        if let url, let key { try? configure(urlString: url, publishableKey: key, save: false) }
    }

    nonisolated static func validProjectURL(_ input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".supabase.co"), !host.hasPrefix("."),
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    func configure(urlString: String, publishableKey: String, save: Bool = true) throws {
        guard let url = Self.validProjectURL(urlString) else { throw AccountError.invalidURL }
        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.lowercased().contains("secret"), !key.lowercased().contains("service_role") else {
            throw AccountError.invalidKey
        }
        authEvents?.cancel()
        usageRefreshID = UUID()
        usageIsRefreshing = false
        workerUsage = nil
        planEntitlement = nil
        billingStatus = nil
        usageError = nil
        let storageKey = "bibbles-\(url.host ?? "account")-auth"
        let auth = AuthClient(
            url: url.appendingPathComponent("auth/v1"),
            headers: ["apikey": key, "Authorization": "Bearer \(key)"],
            flowType: .pkce,
            redirectToURL: Self.callbackURL,
            storageKey: storageKey,
            localStorage: KeychainLocalStorage(service: "com.bibbles.desktop.auth")
        )
        client = auth
        projectURL = url
        projectKey = key
        isConfigured = true
        googleEnabled = false
        appleEnabled = false
        email = auth.currentSession?.user.email
        errorMessage = nil
        if save {
            UserDefaults.standard.set(url.absoluteString, forKey: "bibbles.supabaseURL")
            UserDefaults.standard.set(key, forKey: "bibbles.supabasePublishableKey")
        }
        authEvents = Task { [weak self] in
            for await (event, session) in auth.authStateChanges {
                guard !Task.isCancelled else { return }
                self?.email = session?.user.email
                let id = session?.user.id.uuidString.lowercased()
                if self?.userID != id { self?.userID = id }
                if session == nil {
                    self?.usageRefreshID = UUID()
                    self?.usageIsRefreshing = false
                    self?.workerUsage = nil
                    self?.planEntitlement = nil
                    self?.billingStatus = nil
                }
                if event == .passwordRecovery { self?.needsNewPassword = true }
                if let session, session.user.emailConfirmedAt != nil {
                    ProductAnalytics.shared.signupVerified(userID: session.user.id.uuidString.lowercased())
                }
            }
        }
        Task { [weak self] in
            guard auth.currentSession != nil else { return }
            do { self?.email = try await auth.session.user.email }
            catch { self?.email = nil }
        }
        Task { [weak self] in await self?.refreshProviderStatus(url: url, key: key) }
    }

    func refreshProviders() {
        guard let projectURL, let projectKey else { return }
        providerStatus = "Checking sign-in methods…"
        Task { [weak self] in await self?.refreshProviderStatus(url: projectURL, key: projectKey) }
    }

    private func requireClient() throws -> AuthClient {
        guard let client else { throw AccountError.notConfigured }
        return client
    }

    /// The SDK refreshes an expired session before returning it. Never persist
    /// or log this token outside the SDK's Keychain-backed session storage.
    func workerAccessToken() async throws -> String {
        guard let client, client.currentSession != nil else { throw WorkerError.signInRequired }
        do {
            let session = try await client.session
            email = session.user.email
            return session.accessToken
        } catch {
            email = nil
            throw WorkerError.signInRequired
        }
    }

    func signInWithGoogle() async {
        guard googleEnabled else { errorMessage = "Enable Google in Supabase Authentication → Providers first."; return }
        await perform {
            // Our own sign-in sheet: supabase-swift's built-in one crashes when the sheet is closed.
            let session = try await requireClient().signInWithOAuth(
                provider: .google, redirectTo: Self.callbackURL,
                launchFlow: { url in try await OAuthWebFlow.run(url: url, callbackScheme: "bibbles-auth") })
            email = session.user.email
            ProductAnalytics.shared.authenticationSucceeded(userID: session.user.id.uuidString.lowercased(),
                signedUp: false, method: .google)
            message = "Signed in to Bibbles."
        }
    }

    func signInWithAppleWeb() async {
        guard appleEnabled else { errorMessage = "Enable Apple in Supabase Authentication → Providers first."; return }
        await perform {
            // Our own sign-in sheet: supabase-swift's built-in one crashes when the sheet is closed.
            let session = try await requireClient().signInWithOAuth(
                provider: .apple, redirectTo: Self.callbackURL,
                launchFlow: { url in try await OAuthWebFlow.run(url: url, callbackScheme: "bibbles-auth") })
            email = session.user.email
            ProductAnalytics.shared.authenticationSucceeded(userID: session.user.id.uuidString.lowercased(),
                signedUp: false, method: .apple)
            message = "Signed in to Bibbles."
        }
    }

    /// Create the native Apple request from the button callback, then exchange
    /// its signed ID token for the same Supabase account session.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) -> String {
        let nonce = Self.randomNonce()
        request.requestedScopes = [.email, .fullName]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        return nonce
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        guard appleEnabled else { errorMessage = "Enable Apple in Supabase Authentication → Providers first."; return }
        await perform {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let idToken = String(data: data, encoding: .utf8) else { throw AccountError.invalidAppleToken }
            let auth = try requireClient()
            let session = try await auth.signInWithIdToken(credentials: OpenIDConnectCredentials(
                provider: .apple, idToken: idToken, nonce: nonce))
            email = session.user.email
            ProductAnalytics.shared.authenticationSucceeded(userID: session.user.id.uuidString.lowercased(),
                signedUp: false, method: .apple)
            message = "Signed in to Bibbles."
        }
    }

    func signIn(email: String, password: String) async {
        await perform {
            let session = try await requireClient().signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            self.email = session.user.email
            ProductAnalytics.shared.authenticationSucceeded(userID: session.user.id.uuidString.lowercased(),
                signedUp: false, method: .email)
            message = "Signed in to Bibbles."
        }
    }

    func signUp(email: String, password: String) async {
        await perform {
            let response: AuthResponse
            do {
                response = try await requireClient().signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                                            password: password, redirectTo: Self.callbackURL)
            } catch {
                // With email confirmation off, Supabase says so directly.
                if error.localizedDescription.lowercased().contains("already") {
                    switchToSignIn = true
                    throw AccountError.alreadyRegistered
                }
                throw error
            }
            if let session = response.session {
                self.email = session.user.email
                ProductAnalytics.shared.authenticationSucceeded(userID: session.user.id.uuidString.lowercased(),
                    signedUp: true, method: .email)
                message = "Your Bibbles account is ready."
            } else if response.user.identities?.isEmpty == true {
                // Supabase hides existing accounts by returning a user with no
                // identities and sending no email. Treat it as "already registered".
                switchToSignIn = true
                throw AccountError.alreadyRegistered
            } else {
                let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingVerification = PendingVerification(email: address, kind: .signup)
                ProductAnalytics.shared.awaitingSignupVerification(userID: response.user.id.uuidString.lowercased())
                message = "We sent a verification code to \(address)."
            }
        }
    }

    func acknowledgeSwitchToSignIn() { switchToSignIn = false }

    func resetPassword(email: String) async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform {
            try await requireClient().resetPasswordForEmail(address, redirectTo: Self.callbackURL)
            pendingVerification = PendingVerification(email: address, kind: .recovery)
            message = "If this address has an account, we sent a code to \(address)."
        }
    }

    /// Checks the emailed code. Sign-up codes finish sign-in; reset codes
    /// sign in temporarily and move on to choosing a new password.
    func verifyCode(_ code: String) async {
        guard let pending = pendingVerification else { return }
        let token = code.filter(\.isNumber)
        await perform {
            let response = try await requireClient().verifyOTP(
                email: pending.email, token: token,
                type: pending.kind == .signup ? .signup : .recovery)
            switch pending.kind {
            case .signup:
                if let session = response.session {
                    ProductAnalytics.shared.signupVerified(userID: session.user.id.uuidString.lowercased())
                }
                email = response.session?.user.email ?? pending.email
                pendingVerification = nil
                message = "Email verified. Welcome to Bibbles!"
            case .recovery:
                pendingVerification?.stage = .newPassword
                message = "Code accepted. Choose a new password."
            }
        }
    }

    func resendCode() async {
        guard let pending = pendingVerification, pending.stage == .code else { return }
        await perform {
            switch pending.kind {
            case .signup:
                try await requireClient().resend(email: pending.email, type: .signup, emailRedirectTo: Self.callbackURL)
            case .recovery:
                try await requireClient().resetPasswordForEmail(pending.email, redirectTo: Self.callbackURL)
            }
            message = "We sent a new code to \(pending.email)."
        }
    }

    /// Final step of a password reset: save the new password and stay signed in.
    func setNewPassword(_ password: String) async {
        guard pendingVerification?.stage == .newPassword else { return }
        await perform {
            let user = try await requireClient().update(user: UserAttributes(password: password))
            email = user.email ?? pendingVerification?.email
            pendingVerification = nil
            needsNewPassword = false
            message = "Password updated. You're signed in."
        }
    }

    /// Leaves the code flow. After a verified reset code the temporary
    /// session is signed out so the old password isn't silently kept.
    func cancelVerification() async {
        let wasVerified = pendingVerification?.stage == .newPassword
        pendingVerification = nil
        message = nil
        errorMessage = nil
        if wasVerified {
            try? await client?.signOut(scope: .local)
            email = nil
        }
    }

    func updatePassword(_ password: String) async {
        await perform {
            _ = try await requireClient().update(user: UserAttributes(password: password))
            needsNewPassword = false
            message = "Password updated."
        }
    }

    func handleCallback(_ url: URL) async {
        guard url.scheme == Self.callbackURL.scheme, url.host == Self.callbackURL.host,
              let client else { return }
        await perform {
            let session = try await client.session(from: url)
            email = session.user.email
            needsNewPassword = url.absoluteString.contains("recovery")
            message = needsNewPassword ? "Choose a new password below." : "Email confirmed. You're signed in."
        }
    }

    func signOut() async {
        await perform {
            try await requireClient().signOut(scope: .local)
            email = nil
            usageRefreshID = UUID()
            usageIsRefreshing = false
            workerUsage = nil
            planEntitlement = nil
            billingStatus = nil
            needsNewPassword = false
            pendingVerification = nil
            message = "Signed out on this Mac."
        }
    }

    func refreshWorkerUsage() async {
        guard let requestedEmail = email else {
            workerUsage = nil
            planEntitlement = nil
            billingStatus = nil
            return
        }
        #if BIBBLES_DEVELOPER
        // Local mode: show the last usage synced in server mode; never contact the server.
        if LocalMode.isOn {
            let cached = LocalUsageCache.load()
            workerUsage = cached?.snapshot
            usageError = cached == nil ? "Local mode — usage hasn't been synced in server mode yet." : nil
            return
        }
        #endif
        let requestID = UUID()
        usageRefreshID = requestID
        usageIsRefreshing = true
        defer { if usageRefreshID == requestID { usageIsRefreshing = false } }
        do {
            let payload = try await WorkerAPI.me()
            guard email == requestedEmail, usageRefreshID == requestID else { return }
            guard let snapshot = WorkerUsageSnapshot(payload) else { throw WorkerError.invalidResponse }
            #if BIBBLES_DEVELOPER
            LocalUsageCache.save(payload)
            #endif
            workerUsage = snapshot
            usageError = nil
            if let fromWorker = snapshot.entitlement {
                planEntitlement = fromWorker
            } else {
                let fromSupabase = await fetchEntitlementFromSupabase(plan: snapshot.plan)
                guard email == requestedEmail, usageRefreshID == requestID else { return }
                planEntitlement = fromSupabase
            }
        } catch {
            guard email == requestedEmail, usageRefreshID == requestID else { return }
            workerUsage = nil
            planEntitlement = nil
            usageError = error.localizedDescription
        }
        // A paid Dodo subscription is confirmed by the billing Worker. A failed
        // lookup keeps the last known status rather than flashing "free".
        if let billing = try? await BillingAPI.status() {
            guard email == requestedEmail, usageRefreshID == requestID else { return }
            billingStatus = billing
            if billing.hasAccess, let entitlement = billing.entitlement { planEntitlement = entitlement }
        }
    }

    // MARK: Paid plan (Dodo Payments via the billing Worker)

    /// Buys `plan` (Dodo checkout in the browser) or switches a running
    /// subscription to it, then watches until the new plan is confirmed.
    /// Returns true when checkout opened or the switch was accepted.
    @discardableResult
    func startCheckout(plan: String) async -> Bool {
        guard email != nil, !billingBusy else { return false }
        billingBusy = true
        errorMessage = nil
        message = nil
        defer { billingBusy = false }
        do {
            switch try await BillingAPI.checkout(plan: plan) {
            case .pay(let url):
                NSWorkspace.shared.open(url)
                message = "Finish checkout in your browser. Your plan updates here automatically."
            case .switched(let newPlan):
                message = "Switching you to \(newPlan.capitalized)…"
            }
            watchForPlan(plan)
            return true
        } catch BillingError.alreadySubscribed {
            await refreshWorkerUsage()
            message = BillingError.alreadySubscribed.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Opens Dodo's customer portal: change card, see invoices, or cancel.
    func openBillingPortal() async {
        guard email != nil, !billingBusy else { return }
        billingBusy = true
        errorMessage = nil
        message = nil
        defer { billingBusy = false }
        do {
            NSWorkspace.shared.open(try await BillingAPI.portalURL())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `bibbles-auth://billing?status=…` — the browser coming back from checkout or the portal.
    func handleBillingReturn(_ url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let status = items.first { $0.name == "status" }?.value
        let fromPortal = items.contains { $0.name == "from" && $0.value == "portal" }
        if let status, ["failed", "cancelled", "expired"].contains(status), !fromPortal {
            stopWatchingForPayment()
            errorMessage = "The payment wasn’t completed. No charge was made."
            return
        }
        await refreshWorkerUsage()
        if fromPortal { return }
        if planReached(pendingPlan) {
            stopWatchingForPayment()
            message = "You’re on \((effectivePlanName ?? "your new plan").capitalized) now — thank you!"
        } else {
            message = "Payment received. Confirming your plan…"
            watchForPlan(pendingPlan)
        }
    }

    /// The plan a checkout or switch is waiting on (nil = any paid plan).
    @Published private(set) var pendingPlan: String?

    private func planReached(_ target: String?) -> Bool {
        guard let current = effectivePlanName?.lowercased() else { return false }
        if let target { return current == target.lowercased() }
        return PlanEntitlement.isPremium(plan: current)
    }

    /// Dodo confirms by webhook a few seconds after paying; poll until the plan flips (up to 15 minutes).
    private func watchForPlan(_ target: String?) {
        paymentWatch?.cancel()
        pendingPlan = target
        awaitingPayment = true
        paymentWatch = Task { [weak self] in
            for attempt in 0..<180 {
                try? await Task.sleep(nanoseconds: UInt64(attempt < 24 ? 5 : 10) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.email != nil else { self.awaitingPayment = false; return }
                await self.refreshWorkerUsage()
                if self.planReached(target) {
                    self.awaitingPayment = false
                    self.pendingPlan = nil
                    self.errorMessage = nil
                    self.message = "You’re on \((self.effectivePlanName ?? "your new plan").capitalized) now — thank you!"
                    return
                }
            }
            self?.awaitingPayment = false
        }
    }

    private func stopWatchingForPayment() {
        paymentWatch?.cancel()
        paymentWatch = nil
        pendingPlan = nil
        awaitingPayment = false
    }

    /// Reads the plan expiry straight from Supabase (PostgREST) with the
    /// signed-in user's token. Tries the tables in `entitlementTables`.
    private func fetchEntitlementFromSupabase(plan: String) async -> PlanEntitlement? {
        guard let client, let projectURL, let projectKey,
              let session = try? await client.session else { return nil }
        let userID = session.user.id.uuidString.lowercased()
        var best: PlanEntitlement?
        for source in Self.entitlementTables {
            var components = URLComponents(url: projectURL.appendingPathComponent("rest/v1/\(source.table)"),
                                           resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: source.userColumn, value: "eq.\(userID)"),
                URLQueryItem(name: "limit", value: "20")
            ]
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(projectKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let result = try? await URLSession.shared.data(for: request),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  let rows = (try? JSONSerialization.jsonObject(with: result.0)) as? [[String: Any]] else { continue }
            for row in rows {
                guard let found = PlanEntitlement(row: row, fallbackPlan: plan) else { continue }
                // Keep the latest-ending period when a table holds several rows.
                if let current = best, (current.expiresAt ?? .distantPast) >= (found.expiresAt ?? .distantPast) { continue }
                best = found
            }
            if best != nil { return best }
        }
        return nil
    }

    func deleteAccount() async {
        await perform {
            try await WorkerAPI.deleteAccount()
            if let userID { deletedUserIDs.insert(userID) }
            try? await requireClient().signOut(scope: .local)
            email = nil
            usageRefreshID = UUID()
            usageIsRefreshing = false
            workerUsage = nil
            planEntitlement = nil
            billingStatus = nil
            message = "Your Bibbles account was deleted."
        }
    }

    private func refreshProviderStatus(url: URL, key: String) async {
        var request = URLRequest(url: url.appendingPathComponent("auth/v1/settings"))
        request.setValue(key, forHTTPHeaderField: "apikey")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let providers = object["external"] as? [String: Bool] else {
                providerStatus = "Could not check provider setup. Try again later."
                return
            }
            googleEnabled = providers["google"] == true
            appleEnabled = providers["apple"] == true
            emailEnabled = providers["email"] == true
            providerStatus = ""
        } catch {
            providerStatus = "Could not check provider setup. Try again later."
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        message = nil
        defer { isBusy = false }
        do { try await operation() }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { return }
        catch let error as ASAuthorizationError where error.code == .canceled { return }
        catch { errorMessage = error.localizedDescription }
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private enum AccountError: LocalizedError {
    case invalidURL, invalidKey, notConfigured, invalidAppleToken, alreadyRegistered
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter the HTTPS Project URL from Supabase (…supabase.co)."
        case .invalidKey: return "Enter a publishable or anon key. Never use a service-role key in the app."
        case .notConfigured: return "Connect Bibbles to its account project first."
        case .invalidAppleToken: return "Apple did not return an identity token. Try again."
        case .alreadyRegistered: return "This email already has a Bibbles account. Sign in, or tap Forgot? to reset your password."
        }
    }
}
