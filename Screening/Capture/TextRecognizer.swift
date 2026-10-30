import CoreGraphics
import Vision

nonisolated enum TextRecognizer {
    /// Reads the text in an image on-device, one line per line of text.
    static func text(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            return lines.joined(separator: "\n")
        }.value
    }
}
