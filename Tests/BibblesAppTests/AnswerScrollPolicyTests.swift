import XCTest
import AppKit
import SwiftUI
@testable import BibblesApp

final class AnswerScrollPolicyTests: XCTestCase {
    @MainActor
    private final class AnswerTextModel: ObservableObject {
        @Published var text = "First line"
    }

    private struct AnswerHarness: View {
        @ObservedObject var model: AnswerTextModel
        var body: some View { StreamingAnswerView(text: model.text) }
    }

    func testNewResponseFollowsLatest() {
        XCTAssertTrue(AnswerScrollPolicy().followsLatest)
    }
    func testReadingEarlierTextPausesUntilExplicitlyResumed() {
        var policy = AnswerScrollPolicy()
        policy.scrollUp()
        XCTAssertFalse(policy.followsLatest)
        policy.scrollUp()
        XCTAssertFalse(policy.followsLatest)
        policy.resume()
        XCTAssertTrue(policy.followsLatest)
    }

    @MainActor
    func testLongAnswerActuallyScrollsToBottom() async throws {
        _ = NSApplication.shared
        let model = AnswerTextModel()
        let host = NSHostingView(rootView: AnswerHarness(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        // SwiftUI does not run appearance/layout updates for an off-screen host.
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        model.text = (1...80).map { "Line \($0): A progressively revealed answer." }.joined(separator: "\n")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY + 2, document.bounds.maxY)
    }
}
