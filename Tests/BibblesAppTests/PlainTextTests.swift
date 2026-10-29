import XCTest
@testable import BibblesApp

final class PlainTextTests: XCTestCase {
    func testRemovesMarkdownAndEmDashes() {
        let input = """
        ## Dubai
        - **Burj Khalifa**, the tallest building.
        - **Oil** isn't the main story — trade is. Try `ls`.
        """
        XCTAssertEqual(PlainText.clean(input), """
        Dubai
        Burj Khalifa, the tallest building.
        Oil isn't the main story, trade is. Try ls.
        """)
    }

    func testKeepsMathAndIdentifiers() {
        XCTAssertEqual(PlainText.clean("5 * 3 = 15 and snake_case_name"), "5 * 3 = 15 and snake_case_name")
    }

    func testLeavesCodeAppsAndCodeUntouched() {
        let code = "**not bold** — in a terminal"
        XCTAssertEqual(PlainText.clean(code, forAppBundleID: "com.apple.Terminal"), code)
        let swift = "let a = 1;\nfunc f() {\n  return a * 2;\n}"
        XCTAssertEqual(PlainText.clean(swift, forAppBundleID: "com.apple.Notes"), swift)
    }
}
