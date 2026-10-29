import XCTest
@testable import BibblesApp

final class BillingAPITests: XCTestCase {
    func testOnlyDodoHTTPSPagesAreOpened() {
        XCTAssertTrue(BillingAPI.isTrustedPaymentPage(URL(string: "https://checkout.dodopayments.com/session/cks_1")!))
        XCTAssertTrue(BillingAPI.isTrustedPaymentPage(URL(string: "https://customer.dodopayments.com/portal")!))
        XCTAssertFalse(BillingAPI.isTrustedPaymentPage(URL(string: "http://checkout.dodopayments.com/x")!))
        XCTAssertFalse(BillingAPI.isTrustedPaymentPage(URL(string: "https://dodopayments.com.evil.example/x")!))
        XCTAssertFalse(BillingAPI.isTrustedPaymentPage(URL(string: "https://evil-dodopayments.com/x")!))
        XCTAssertThrowsError(try BillingAPI.link(from: ["checkout_url": "https://example.com/pay"], key: "checkout_url"))
    }

    func testReturnURLIsRecognised() {
        XCTAssertTrue(BillingAPI.isReturnURL(URL(string: "bibbles-auth://billing?status=active")!))
        XCTAssertFalse(BillingAPI.isReturnURL(URL(string: "bibbles-auth://callback#access_token=x")!))
    }

    func testServerErrorsMapToFriendlyMessages() {
        XCTAssertEqual(BillingError.from(status: 401, payload: nil), .signInRequired)
        XCTAssertEqual(BillingError.from(status: 409, payload: ["error": "already_subscribed"]), .alreadySubscribed)
        XCTAssertEqual(BillingError.from(status: 409, payload: ["error": "plan_change_pending"]), .planChangePending)
        XCTAssertEqual(BillingError.from(status: 404, payload: ["error": "no_subscription"]), .noSubscription)
        XCTAssertEqual(BillingError.from(status: 503, payload: ["error": "billing_not_configured"]), .notConfigured)
        XCTAssertEqual(BillingError.from(status: 502, payload: ["error": "payments_unavailable"]), .unavailable)
    }

    func testActiveStatusCarriesRenewalDate() throws {
        let status = try XCTUnwrap(BillingStatus([
            "plan": "sigma", "has_access": true, "manage_available": true,
            "subscription": ["plan": "sigma", "status": "active", "started_at": "2026-10-11T05:00:00Z",
                             "access_ends_at": NSNull(), "renews_at": "2026-11-11T05:00:00Z"],
            "plan_history": [] as [Any]
        ]))
        XCTAssertTrue(status.hasAccess)
        XCTAssertTrue(status.manageAvailable)
        XCTAssertNotNil(status.entitlement?.renewsAt)
        XCTAssertNil(status.entitlement?.expiresAt)
        XCTAssertTrue(PlanEntitlement.isPremium(plan: status.plan))
    }

    func testStatusCarriesCurrentStartAndHistory() throws {
        let status = try XCTUnwrap(BillingStatus([
            "plan": "omega", "has_access": true, "manage_available": true,
            "subscription": ["plan": "omega", "status": "active", "started_at": "2026-10-13T05:00:00Z",
                             "access_ends_at": NSNull(), "renews_at": "2026-11-13T05:00:00Z"],
            "plan_history": [
                ["plan": "alpha", "started_at": "2026-09-01T00:00:00Z", "ended_at": "2026-10-01T00:00:00Z", "end_reason": "upgrade"],
                ["plan": "sigma", "started_at": "2026-10-01T00:00:00Z", "ended_at": "2026-10-13T05:00:00Z", "end_reason": "upgrade"]
            ]
        ]))
        XCTAssertNotNil(status.currentSince)
        XCTAssertEqual(status.history.map(\.plan), ["sigma", "alpha"], "newest first")
    }

    func testFreeStatusHasNoEntitlement() throws {
        let status = try XCTUnwrap(BillingStatus(["plan": "alpha", "has_access": false, "manage_available": false,
                                                  "subscription": NSNull()]))
        XCTAssertFalse(status.hasAccess)
        XCTAssertNil(status.entitlement)
        XCTAssertNil(BillingStatus(["has_access": true]))
    }

    func testPlansParseWithPricesAndFormatting() throws {
        let json = """
        {"plans":[
          {"id":"alpha","name":"Alpha","tagline":"Free","features":["Basics"],"free":true,"highlight":false,
           "price":{"amount":0,"currency":null,"interval":null,"interval_count":null}},
          {"id":"sigma","name":"Sigma","features":["More"],"free":false,"highlight":false,
           "price":{"amount":49900,"currency":"INR","interval":"Month","interval_count":1,"tax_inclusive":true}},
          {"id":"omega","name":"Omega","features":["Most"],"free":false,"highlight":true,"price":null}
        ]}
        """
        let plans = try BillingPlan.list(from: Data(json.utf8))
        XCTAssertEqual(plans.map(\.id), ["alpha", "sigma", "omega"])
        XCTAssertTrue(plans[0].isFree)
        XCTAssertFalse(plans[0].isPurchasable)
        XCTAssertEqual(plans[0].price?.formatted, "Free")
        XCTAssertTrue(plans[1].isPurchasable)
        XCTAssertEqual(plans[1].price?.formatted, "₹499")
        XCTAssertEqual(plans[1].price?.period, "/month")
        XCTAssertTrue(plans[2].isHighlighted)
        XCTAssertFalse(plans[2].isPurchasable, "a plan whose price couldn't be loaded can't be bought")
    }

    func testPriceFormattingKeepsCents() {
        let price = BillingPlan.Price(amount: 999, currency: "USD", interval: "Month", intervalCount: 1, taxInclusive: nil)
        XCTAssertTrue(price.formatted.contains("9.99"))
        let quarterly = BillingPlan.Price(amount: 100, currency: "USD", interval: "Month", intervalCount: 3, taxInclusive: nil)
        XCTAssertEqual(quarterly.period, "every 3 months")
    }

    func testCheckoutResult() throws {
        XCTAssertEqual(try BillingAPI.checkoutResult(from: ["changed": true, "plan": "omega"], plan: "omega"), .switched(plan: "omega"))
        XCTAssertEqual(try BillingAPI.checkoutResult(from: ["checkout_url": "https://checkout.dodopayments.com/s/1"], plan: "sigma"),
                       .pay(URL(string: "https://checkout.dodopayments.com/s/1")!))
        XCTAssertThrowsError(try BillingAPI.checkoutResult(from: ["checkout_url": "https://phish.example/s/1"], plan: "sigma"))
    }
}
