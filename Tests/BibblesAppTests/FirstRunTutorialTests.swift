import XCTest
@testable import BibblesApp

final class FirstRunTutorialTests: XCTestCase {
    func testTutorialIsAutomaticallyPresentedOnlyOnce() throws {
        let suite = "BibblesTutorialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TutorialLaunchPolicy.claimFirstPresentation(defaults: defaults))
        XCTAssertFalse(TutorialLaunchPolicy.claimFirstPresentation(defaults: defaults))
    }

    func testExistingUsersDoNotRepeatOnboarding() throws {
        let suite = "BibblesTutorialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "didShowGettingStarted.v1")
        XCTAssertFalse(TutorialLaunchPolicy.claimFirstPresentation(defaults: defaults))
    }

    func testPermissionStepsUseTheirOwnLiveStatus() {
        let status = PermissionSnapshot(accessibility: false, microphone: .authorized, screenRecording: true)
        XCTAssertTrue(TutorialStep.screen.isGranted(status))
        XCTAssertFalse(TutorialStep.accessibility.isGranted(status))
        XCTAssertTrue(TutorialStep.microphone.isGranted(status))
        let denied = PermissionSnapshot(accessibility: true, microphone: .denied, screenRecording: false)
        XCTAssertFalse(TutorialStep.screen.isGranted(denied))
        XCTAssertTrue(TutorialStep.accessibility.isGranted(denied))
        XCTAssertFalse(TutorialStep.microphone.isGranted(denied))
    }

    func testScreenPermissionRequiresAnActualFrameBeforeAdvancing() {
        let allowed = PermissionSnapshot(accessibility: false, microphone: .notDetermined, screenRecording: true)
        XCTAssertNil(TutorialStep.screen.automaticNext(status: allowed, verifiedFrame: false))
        XCTAssertEqual(TutorialStep.screen.automaticNext(status: allowed, verifiedFrame: true), .accessibility)
        let revoked = PermissionSnapshot(accessibility: true, microphone: .authorized, screenRecording: false)
        XCTAssertNil(TutorialStep.screen.automaticNext(status: revoked, verifiedFrame: true))
    }

    func testLiveGrantsAdvanceAndWelcomeAndHandoffRemainUserControlled() {
        let granted = PermissionSnapshot(accessibility: true, microphone: .authorized, screenRecording: true)
        XCTAssertEqual(TutorialStep.accessibility.automaticNext(status: granted, verifiedFrame: false), .microphone)
        XCTAssertEqual(TutorialStep.microphone.automaticNext(status: granted, verifiedFrame: false), .ready)
        XCTAssertNil(TutorialStep.welcome.automaticNext(status: granted, verifiedFrame: true))
        XCTAssertNil(TutorialStep.ready.automaticNext(status: granted, verifiedFrame: true))
        let denied = PermissionSnapshot(accessibility: false, microphone: .denied, screenRecording: true)
        XCTAssertNil(TutorialStep.accessibility.automaticNext(status: denied, verifiedFrame: true))
        XCTAssertNil(TutorialStep.microphone.automaticNext(status: denied, verifiedFrame: true))
    }

    func testSetupResumesAfterSystemRequiresReopening() throws {
        let suite = "BibblesTutorialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "didShowGettingStarted.v1")
        defaults.set(TutorialStep.screen.rawValue, forKey: TutorialLaunchPolicy.pendingStepKey)
        XCTAssertTrue(TutorialLaunchPolicy.claimFirstPresentation(defaults: defaults))
        defaults.removeObject(forKey: TutorialLaunchPolicy.pendingStepKey)
        XCTAssertFalse(TutorialLaunchPolicy.claimFirstPresentation(defaults: defaults))
    }

    func testFloatingCardStaysWithinNegativeOriginDisplay() {
        let screen = CGRect(x: -1600, y: -900, width: 1600, height: 900)
        for pointer in [CGPoint(x: -1599, y: -899), CGPoint(x: -1, y: -1)] {
            let card = TutorialGeometry.frame(in: screen, pointer: pointer)
            XCTAssertTrue(screen.insetBy(dx: 18, dy: 18).contains(card))
            XCTAssertTrue(card.contains(TutorialGeometry.avatar(in: card)))
        }
    }

    func testSettingsGuidanceRejectsAmbiguousOrUnverifiedRows() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let descriptor = CaptureDescriptor(displayID: 1, displayFrameInQuartzPoints: screen,
            capturePixelSize: CGSize(width: 2000, height: 1600), cropRectInCapturePixels: CGRect(x: 0, y: 0, width: 2000, height: 1600),
            cropRectInQuartzPoints: screen, backingScaleFactor: 2, rotationDegrees: 0, capturedAt: Date())
        let row = OCRObservation(text: "Bibbles", confidence: 0.95,
            normalizedRect: NormalizedRect(x: 0.2, y: 0.3, width: 0.1, height: 0.03))
        XCTAssertNotNil(TutorialSettingsTarget.bibblesRow(words: [row], descriptor: descriptor, window: screen))
        XCTAssertNil(TutorialSettingsTarget.bibblesRow(words: [row, row], descriptor: descriptor, window: screen))
        XCTAssertNil(TutorialSettingsTarget.bibblesRow(words: [row], descriptor: descriptor,
            window: CGRect(x: 800, y: 0, width: 200, height: 200)))
        let low = OCRObservation(text: "Bibbles", confidence: 0.4, normalizedRect: row.normalizedRect)
        XCTAssertNil(TutorialSettingsTarget.bibblesRow(words: [low], descriptor: descriptor, window: screen))
    }
}
