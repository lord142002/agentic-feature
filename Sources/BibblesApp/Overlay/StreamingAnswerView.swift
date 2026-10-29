import AppKit
import SwiftUI

/// Following is opt-out for each response, never reset by another streamed token.
struct AnswerScrollPolicy {
    private(set) var followsLatest = true
    mutating func scrollUp() { followsLatest = false }
    mutating func resume() { followsLatest = true }
}

struct StreamingAnswerView: View {
    let text: String
    @State private var policy = AnswerScrollPolicy()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    AnswerScrollAnchor(text: text, followsLatest: policy.followsLatest)
                        .frame(height: 1)
                }
            }
            .background(AnswerScrollIntentObserver {
                policy.scrollUp()
            })
            .frame(minHeight: 90, maxHeight: 320)

            if !policy.followsLatest {
                Button {
                    policy.resume()
                } label: {
                    Label("Follow answer", systemImage: "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Resume automatic scrolling to the latest text")
            }
        }
    }
}

/// AppKit's clip view knows the answer's final laid-out position. Scrolling
/// this anchor avoids asking SwiftUI to resolve a stale ID during token bursts.
private struct AnswerScrollAnchor: NSViewRepresentable {
    let text: String
    let followsLatest: Bool

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.update(text: text, followsLatest: followsLatest)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.cancelScroll() }

    final class AnchorView: NSView {
        private var lastText: String?
        private var lastFollowsLatest = false
        private var pendingScroll: DispatchWorkItem?

        func update(text: String, followsLatest: Bool) {
            let needsScroll = lastText != text || (!lastFollowsLatest && followsLatest)
            lastText = text
            lastFollowsLatest = followsLatest
            guard followsLatest, needsScroll else {
                if !followsLatest { cancelScroll() }
                return
            }
            // Keep the first pending scroll during a token burst; later updates
            // will be included in the layout that it reveals.
            guard pendingScroll == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.lastFollowsLatest else { return }
                self.scrollToVisible(self.bounds)
                self.pendingScroll = nil
            }
            pendingScroll = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        func cancelScroll() {
            pendingScroll?.cancel()
            pendingScroll = nil
        }
    }
}

/// Observes only real upward scrolling over this card; programmatic scrolling
/// and content growth cannot accidentally turn following off. Events pass through.
private struct AnswerScrollIntentObserver: NSViewRepresentable {
    let onScrollUp: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScrollUp = onScrollUp }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var onScrollUp: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      event.scrollingDeltaY > 0 else { return event }
                self.onScrollUp?()
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { stop() }
    }
}
