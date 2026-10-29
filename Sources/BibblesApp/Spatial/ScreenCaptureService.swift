import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

struct ScreenCaptureResult {
    let image: CGImage
    let descriptor: CaptureDescriptor
    /// The unscaled capture, for reading small text such as chart price scales.
    var fullResolution: CGImage? = nil
}

enum ScreenCaptureServiceError: LocalizedError {
    case permissionRequired
    case displayUnavailable
    case invalidFrame
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "macOS denied screen capture for this Bibbles build. If Bibbles is already enabled in Screen & System Audio Recording, remove its old entry, add this exact Bibbles.app again, enable it, then quit and reopen Bibbles. Development builds signed ad-hoc can lose approval after a rebuild."
        case .displayUnavailable: return "The display under the cursor is unavailable."
        case .invalidFrame: return "ScreenCaptureKit returned an invalid frame."
        case .cropFailed: return "Bibbles could not crop the captured screen image."
        }
    }
}

final class ScreenCaptureService {
    @MainActor
    func captureFocusRegion(_ selection: CircleFocusSelection) async throws -> ScreenCaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureServiceError.permissionRequired }
        func matchingScreen() -> NSScreen? {
            NSScreen.screens.first {
                let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return number?.uint32Value == selection.displayID && $0.frame == selection.displayFrame
                    && $0.backingScaleFactor == selection.scale
                    && normalizedRotation(CGDisplayRotation(selection.displayID)) == selection.rotation
            }
        }
        guard matchingScreen() != nil else { throw ScreenCaptureServiceError.displayUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }),
              matchingScreen() != nil else { throw ScreenCaptureServiceError.displayUnavailable }
        let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let fullImage = try await OneShotDisplayCapture.capture(display: display, excludingApplications: excluded)
        try Task.checkCancellation()
        guard matchingScreen() != nil else { throw ScreenCaptureServiceError.displayUnavailable }
        // Use the returned framebuffer dimensions, including rotated/scaled displays.
        let geometry = DisplayGeometry(displayID: display.displayID, frameInQuartzPoints: selection.displayFrame,
            pixelSize: CGSize(width: fullImage.width, height: fullImage.height),
            backingScaleFactor: selection.scale, rotationDegrees: selection.rotation)
        let crop = try CaptureCropPlanner.regionCrop(rect: selection.rect, display: geometry)
        guard let image = fullImage.cropping(to: crop.rectInCapturePixels) else { throw ScreenCaptureServiceError.cropFailed }
        let scale = min(1, 1600 / CGFloat(max(image.width, image.height)))
        let output: CGImage
        if scale < 1 {
            let resized = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let result = CIContext().createCGImage(resized, from: resized.extent) else { throw ScreenCaptureServiceError.invalidFrame }
            output = result
        } else { output = image }
        return ScreenCaptureResult(image: output, descriptor: CaptureDescriptor(displayID: display.displayID,
            displayFrameInQuartzPoints: selection.displayFrame, capturePixelSize: geometry.pixelSize,
            cropRectInCapturePixels: crop.rectInCapturePixels, cropRectInQuartzPoints: crop.rectInQuartzPoints,
            backingScaleFactor: selection.scale, rotationDegrees: selection.rotation, capturedAt: Date()),
            fullResolution: image)
    }

    func captureCursorCrop(
        cursor: CGPoint = NSEvent.mouseLocation,
        maximumLongEdgePixels: CGFloat = 1_024
    ) async throws -> ScreenCaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureServiceError.permissionRequired
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }),
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == displayNumber.uint32Value }) else {
            throw ScreenCaptureServiceError.displayUnavailable
        }

        let geometry = DisplayGeometry(
            displayID: display.displayID,
            frameInQuartzPoints: screen.frame,
            pixelSize: CGSize(width: display.width, height: display.height),
            backingScaleFactor: screen.backingScaleFactor,
            rotationDegrees: normalizedRotation(CGDisplayRotation(display.displayID))
        )
        let crop = try CaptureCropPlanner.cursorCrop(
            cursor: cursor,
            display: geometry,
            maximumLongEdgePixels: maximumLongEdgePixels
        )
        let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let fullImage = try await OneShotDisplayCapture.capture(
            display: display,
            excludingApplications: excludedApps
        )
        guard let cropped = fullImage.cropping(to: crop.rectInCapturePixels) else {
            throw ScreenCaptureServiceError.cropFailed
        }

        return ScreenCaptureResult(
            image: cropped,
            descriptor: CaptureDescriptor(
                displayID: display.displayID,
                displayFrameInQuartzPoints: screen.frame,
                capturePixelSize: geometry.pixelSize,
                cropRectInCapturePixels: crop.rectInCapturePixels,
                cropRectInQuartzPoints: crop.rectInQuartzPoints,
                backingScaleFactor: screen.backingScaleFactor,
                rotationDegrees: geometry.rotationDegrees,
                capturedAt: Date()
            )
        )
    }

    func captureDisplayOverview(
        cursor: CGPoint = NSEvent.mouseLocation,
        maximumLongEdgePixels: CGFloat = 1_600
    ) async throws -> ScreenCaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureServiceError.permissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }),
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == displayNumber.uint32Value }) else {
            throw ScreenCaptureServiceError.displayUnavailable
        }
        let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let fullImage = try await OneShotDisplayCapture.capture(
            display: display,
            excludingApplications: excludedApps
        )
        let longest = CGFloat(max(fullImage.width, fullImage.height))
        let scale = min(1, maximumLongEdgePixels / longest)
        let image: CGImage
        if scale < 1 {
            let resized = CIImage(cgImage: fullImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let rendered = CIContext().createCGImage(resized, from: resized.extent) else {
                throw ScreenCaptureServiceError.invalidFrame
            }
            image = rendered
        } else {
            image = fullImage
        }
        let fullPixels = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        return ScreenCaptureResult(
            image: image,
            descriptor: CaptureDescriptor(
                displayID: display.displayID,
                displayFrameInQuartzPoints: screen.frame,
                capturePixelSize: fullPixels.size,
                cropRectInCapturePixels: fullPixels,
                cropRectInQuartzPoints: screen.frame,
                backingScaleFactor: screen.backingScaleFactor,
                rotationDegrees: normalizedRotation(CGDisplayRotation(display.displayID)),
                capturedAt: Date()
            ),
            fullResolution: fullImage
        )
    }

    private func normalizedRotation(_ value: Double) -> Int {
        let rounded = Int(value.rounded()) % 360
        return rounded >= 0 ? rounded : rounded + 360
    }
}

private final class OneShotDisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let context = CIContext(options: nil)
    private let queue = DispatchQueue(label: "com.bibbles.capture.oneshot", qos: .userInitiated)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var completed = false
    private var timeoutTask: Task<Void, Never>?

    static func capture(display: SCDisplay, excludingApplications: [SCRunningApplication]) async throws -> CGImage {
        let session = OneShotDisplayCapture()
        return try await withTaskCancellationHandler {
            try await session.start(display: display, excludingApplications: excludingApplications)
        } onCancel: {
            session.complete(.failure(CancellationError()))
        }
    }

    private func start(display: SCDisplay, excludingApplications: [SCRunningApplication]) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludingApplications,
            exceptingWindows: []
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !completed else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.stream = stream
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.complete(.failure(ScreenCaptureServiceError.invalidFrame))
            }
            lock.unlock()
            Task {
                guard !self.hasCompleted else { return }
                do {
                    try await stream.startCapture()
                    if self.hasCompleted { try? await stream.stopCapture() }
                }
                catch { self.complete(.failure(error)) }
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else {
            complete(.failure(ScreenCaptureServiceError.invalidFrame))
            return
        }
        complete(.success(image))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        complete(.failure(error))
    }

    private var hasCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    private func complete(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        Task { try? await stream?.stopCapture() }
        continuation?.resume(with: result)
    }
}
