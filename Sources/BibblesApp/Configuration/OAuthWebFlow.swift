import AppKit
import AuthenticationServices
import Foundation

/// Shows the browser sign-in sheet for Google / Apple (web) and returns the
/// callback URL that Supabase turns into a session.
///
/// Replaces supabase-swift's built-in ASWebAuthenticationSession helper. That
/// helper creates its completion closure inside a main-actor closure, so Swift
/// treats it as main-actor only — but macOS calls it on a background XPC queue
/// when the user closes the sheet, and Swift's runtime isolation check then
/// crashes the app (EXC_BREAKPOINT in _dispatch_assert_queue_fail). Here the
/// completion is built outside any actor, so it may run on any thread.
enum OAuthWebFlow {
    @MainActor
    static func run(url: URL, callbackScheme: String) async throws -> URL {
        let anchor = OAuthPresentationAnchor()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme,
                completionHandler: completion(resuming: continuation, keepingAlive: anchor)
            )
            session.presentationContextProvider = anchor
            session.start()
        }
    }

    /// Deliberately not main-actor isolated: macOS may call it from any thread.
    private static func completion(
        resuming continuation: CheckedContinuation<URL, Error>,
        keepingAlive anchor: OAuthPresentationAnchor
    ) -> @Sendable (URL?, Error?) -> Void {
        { url, error in
            withExtendedLifetime(anchor) {}
            if let url {
                continuation.resume(returning: url)
            } else {
                continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
            }
        }
    }
}

/// Same anchor supabase-swift uses by default.
final class OAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}
