import Foundation
import XCTest
@testable import BibblesApp

final class NetworkRecoveryTests: XCTestCase {
    private var interruptedHandshake: NSError {
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -1200,
                                 userInfo: ["_kCFStreamErrorCodeKey": -9816])
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
                       userInfo: [NSUnderlyingErrorKey: underlying])
    }

    func testRetriesAbruptHandshakeOnce() async throws {
        var attempts = 0
        let result: Int = try await NetworkRecovery.onceAfterAbruptTLS {
            attempts += 1
            if attempts == 1 { throw interruptedHandshake }
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(attempts, 2)
    }

    func testDoesNotRetryCertificateTrustFailure() async {
        var attempts = 0
        let trustError = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        do {
            let _: Int = try await NetworkRecovery.onceAfterAbruptTLS {
                attempts += 1
                throw trustError
            }
            XCTFail("Expected certificate trust failure")
        } catch {
            XCTAssertEqual((error as NSError).code, NSURLErrorServerCertificateUntrusted)
            XCTAssertEqual(attempts, 1)
        }
    }

    func testSecondHandshakeFailureStopsAfterOneRetry() async {
        var attempts = 0
        do {
            let _: Int = try await NetworkRecovery.onceAfterAbruptTLS {
                attempts += 1
                throw interruptedHandshake
            }
            XCTFail("Expected repeated handshake failure")
        } catch {
            XCTAssertTrue(NetworkRecovery.isAbruptTLSClose(error))
            XCTAssertEqual(attempts, 2)
        }
    }
}
