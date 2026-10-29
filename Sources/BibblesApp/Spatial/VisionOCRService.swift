import CoreGraphics
import Foundation
@preconcurrency import Vision

struct OCRObservation: Equatable {
    let text: String
    let confidence: Float
    let normalizedRect: NormalizedRect
}

struct VisionOCRService {
    /// `accurate` is slower but reads small text (like chart price scales) reliably.
    func recognizeText(in image: CGImage, accurate: Bool = false) async throws -> [OCRObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap {
                    observation -> OCRObservation? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox
                    return OCRObservation(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        normalizedRect: NormalizedRect(
                            x: box.minX,
                            y: 1 - box.maxY,
                            width: box.width,
                            height: box.height
                        )
                    )
                }
                continuation.resume(returning: observations)
            }
            request.recognitionLevel = accurate ? .accurate : .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US", "hi-IN"]

            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
