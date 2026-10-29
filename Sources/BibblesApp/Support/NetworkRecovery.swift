import Foundation

enum NetworkRecovery {
    /// CFNetwork -9816 is errSSLClosedNoNotify: the peer ended the TLS stream
    /// without completing the handshake. A certificate trust failure is not
    /// retried and never bypassed.
    static func isAbruptTLSClose(_ error: Error) -> Bool {
        if case TranscriptionStreamError.secureConnectionInterrupted = error { return true }
        let nsError = error as NSError
        if (nsError.domain == NSURLErrorDomain || nsError.domain == "kCFErrorDomainCFNetwork"),
           nsError.code == NSURLErrorSecureConnectionFailed,
           (nsError.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue == -9816 {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isAbruptTLSClose(underlying)
        }
        return false
    }

    static func onceAfterAbruptTLS<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isAbruptTLSClose(error) else { throw error }
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            return try await operation()
        }
    }
}
