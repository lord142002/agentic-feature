import XCTest
@testable import BibblesApp

final class AccountSessionTests: XCTestCase {
    func testAcceptsOnlyProjectRootURL() {
        XCTAssertNotNil(AccountSession.validProjectURL("https://example.supabase.co"))
        XCTAssertNil(AccountSession.validProjectURL("http://example.supabase.co"))
        XCTAssertNil(AccountSession.validProjectURL("https://example.supabase.co.evil.test"))
        XCTAssertNil(AccountSession.validProjectURL("https://example.supabase.co/auth/v1"))
        XCTAssertNil(AccountSession.validProjectURL("https://user@example.supabase.co"))
    }
}
