import Foundation

/// Paid plans through the Bibbles billing Worker (Dodo Payments).
///
/// The app holds no payment credential. It sends the signed-in user's
/// Supabase token; the Worker creates the Dodo checkout or billing-portal
/// link, and Dodo's signed webhooks — never the app — change the plan.
enum BillingAPI {
    /// Override with `BibblesBillingURL` in Info.plist or `BIBBLES_BILLING_URL`.
    static var baseURL: URL {
        let configured = ProcessInfo.processInfo.environment["BIBBLES_BILLING_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "BibblesBillingURL") as? String
        if let configured, let url = URL(string: configured), url.scheme == "https" { return url }
        return URL(string: "https://bibbles-billing.bibbles.workers.dev")!
    }

    /// `bibbles-auth://billing` — where the browser returns after checkout or the portal.
    /// (Same URL scheme as the sign-in callback, already registered in Info.plist.)
    static let returnScheme = "bibbles-auth"
    static let returnHost = "billing"

    static func isReturnURL(_ url: URL) -> Bool {
        url.scheme == returnScheme && url.host == returnHost
    }

    /// Opens only HTTPS pages on Dodo's own domains, whatever the server says.
    static func isTrustedPaymentPage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "dodopayments.com" || host.hasSuffix(".dodopayments.com")
    }

    enum CheckoutResult: Equatable {
        /// Open this Dodo page to pay.
        case pay(URL)
        /// An existing subscription was switched (e.g. Sigma → Omega); no page to open.
        case switched(plan: String)
    }

    /// Starts buying `plan` ("sigma", "omega"), or switches a running subscription to it.
    static func checkout(plan: String, session: URLSession = .shared) async throws -> CheckoutResult {
        let body = try JSONSerialization.data(withJSONObject: ["plan": plan])
        let payload = try await send(path: "v1/billing/checkout", method: "POST", body: body, session: session)
        return try checkoutResult(from: payload, plan: plan)
    }

    static func checkoutResult(from payload: [String: Any], plan: String) throws -> CheckoutResult {
        if payload["changed"] as? Bool == true { return .switched(plan: payload["plan"] as? String ?? plan) }
        return .pay(try link(from: payload, key: "checkout_url"))
    }

    /// The plans for the "Choose your plan" window, with live Dodo prices. No sign-in needed.
    static func plans(session: URLSession = .shared) async throws -> [BillingPlan] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/billing/plans"))
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BillingError.unavailable
        }
        return try BillingPlan.list(from: data)
    }

    static func portalURL(session: URLSession = .shared) async throws -> URL {
        try link(from: await send(path: "v1/billing/portal", method: "POST", session: session), key: "url")
    }

    static func status(session: URLSession = .shared) async throws -> BillingStatus {
        guard let status = BillingStatus(try await send(path: "v1/billing/status", method: "GET", session: session)) else {
            throw BillingError.invalidResponse
        }
        return status
    }

    static func link(from payload: [String: Any], key: String) throws -> URL {
        guard let value = payload[key] as? String, let url = URL(string: value), isTrustedPaymentPage(url) else {
            throw BillingError.invalidResponse
        }
        return url
    }

    private static func send(path: String, method: String, body: Data? = nil,
                             session: URLSession) async throws -> [String: Any] {
        let token = try await AccountSession.shared.workerAccessToken()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BillingError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else { throw BillingError.from(status: http.statusCode, payload: object) }
        guard let object else { throw BillingError.invalidResponse }
        return object
    }
}

enum BillingError: LocalizedError, Equatable {
    case signInRequired
    case alreadySubscribed
    /// An earlier Sigma ⇄ Omega switch is still waiting for its payment.
    case planChangePending
    case unknownPlan
    case noSubscription
    case notConfigured
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Please sign in to Bibbles to manage your plan."
        case .alreadySubscribed: return "You’re already on this plan."
        case .planChangePending: return "Your last plan change is still being processed. Finish its payment page, or try again in a few minutes."
        case .unknownPlan: return "That plan isn’t available right now."
        case .noSubscription: return "There’s no Bibbles subscription on this account yet."
        case .notConfigured: return "Payments aren’t set up yet. Please try again later."
        case .unavailable: return "Payments are unavailable right now. Please try again in a moment."
        case .invalidResponse: return "Bibbles received an unreadable billing response. Please retry."
        }
    }

    static func from(status: Int, payload: [String: Any]?) -> BillingError {
        switch (status, payload?["error"] as? String ?? "") {
        case (401, _), (_, "unauthorized"): return .signInRequired
        case (_, "plan_change_pending"): return .planChangePending
        case (_, "already_subscribed"), (409, _): return .alreadySubscribed
        case (_, "no_subscription"): return .noSubscription
        case (_, "unknown_plan"): return .unknownPlan
        case (_, "billing_not_configured"): return .notConfigured
        default: return .unavailable
        }
    }
}

/// `GET /v1/billing/status` — the subscription as recorded from Dodo's webhooks.
struct BillingStatus: Equatable {
    let plan: String
    let hasAccess: Bool
    let manageAvailable: Bool
    let entitlement: PlanEntitlement?
    /// When the current paid plan began (nil on the free plan).
    let currentSince: Date?
    /// Finished paid periods, newest first.
    let history: [WorkerUsageSnapshot.PastPlan]

    init?(_ payload: [String: Any]) {
        guard let plan = payload["plan"] as? String, !plan.isEmpty else { return nil }
        self.plan = plan
        hasAccess = payload["has_access"] as? Bool ?? false
        manageAvailable = payload["manage_available"] as? Bool ?? false
        entitlement = hasAccess ? PlanEntitlement(payload: payload, fallbackPlan: plan) : nil
        let subscription = payload["subscription"] as? [String: Any]
        currentSince = hasAccess ? WorkerUsageSnapshot.date(subscription?["started_at"]) : nil
        history = ((payload["plan_history"] as? [Any]) ?? []).prefix(100)
            .compactMap(WorkerUsageSnapshot.PastPlan.init)
            .sorted { $0.endedAt > $1.endedAt }
    }
}

/// One card in the "Choose your plan" window (`GET /v1/billing/plans`).
struct BillingPlan: Identifiable, Equatable {
    struct Price: Equatable {
        /// In the currency's smallest unit (paise, cents), as Dodo stores it.
        let amount: Int
        let currency: String?
        let interval: String?
        let intervalCount: Int
        let taxInclusive: Bool?

        /// "₹499", "$9.99", "Free".
        var formatted: String {
            guard amount > 0, let currency, !currency.isEmpty else { return "Free" }
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency.uppercased()
            if currency.uppercased() == "INR" { formatter.locale = Locale(identifier: "en_IN") }
            let digits = formatter.maximumFractionDigits
            var value = Decimal(amount)
            for _ in 0..<digits { value /= 10 }
            if amount % Int(pow(10, Double(digits))) == 0 { formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = 0 }
            return formatter.string(from: value as NSDecimalNumber) ?? "\(currency.uppercased()) \(value)"
        }

        /// "/month", "/year", "every 3 months"; empty for free.
        var period: String {
            guard amount > 0, let interval else { return "" }
            let unit = interval.lowercased()
            return intervalCount <= 1 ? "/\(unit)" : "every \(intervalCount) \(unit)s"
        }
    }

    let id: String
    let name: String
    let tagline: String
    let features: [String]
    let isFree: Bool
    let isHighlighted: Bool
    /// Nil when the plan's price couldn't be loaded (not set up yet): the plan can't be bought.
    let price: Price?

    var isPurchasable: Bool { !isFree && price != nil }

    init?(_ object: [String: Any]) {
        guard let id = (object["id"] as? String)?.lowercased(), !id.isEmpty else { return nil }
        self.id = id
        name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id.capitalized
        tagline = object["tagline"] as? String ?? ""
        features = (object["features"] as? [String] ?? []).prefix(8).map { $0 }
        isFree = object["free"] as? Bool ?? false
        isHighlighted = object["highlight"] as? Bool ?? false
        if let raw = object["price"] as? [String: Any], let amount = (raw["amount"] as? NSNumber)?.intValue {
            price = Price(amount: amount, currency: raw["currency"] as? String, interval: raw["interval"] as? String,
                          intervalCount: (raw["interval_count"] as? NSNumber)?.intValue ?? 1,
                          taxInclusive: raw["tax_inclusive"] as? Bool)
        } else {
            price = nil
        }
    }

    static func list(from data: Data) throws -> [BillingPlan] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["plans"] as? [[String: Any]] else { throw BillingError.invalidResponse }
        let plans = items.compactMap(BillingPlan.init)
        guard !plans.isEmpty else { throw BillingError.invalidResponse }
        return plans
    }
}
