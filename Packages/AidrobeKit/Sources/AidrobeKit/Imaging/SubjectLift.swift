import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// On-device background removal with Apple Vision subject lifting.
///
/// Unlike the server's generative cutout, every opaque pixel in the result is
/// the user's own pixel: the mask only decides which ones to keep, so colour,
/// pattern and cut cannot change. It is class-agnostic — a mirror selfie lifts
/// the whole person (and the phone), so callers should treat several instances
/// or a near-full-frame mask as "not a single garment" and keep the original.
public enum SubjectLift {
    public struct Result: @unchecked Sendable {
        /// Original pixels outside the subject made transparent, cropped to the subject.
        public let image: CGImage
        /// Fraction of the frame covered by the kept subject (0…1).
        public let coverage: Double
        /// Number of separate foreground instances Vision found.
        public let instanceCount: Int

        /// Heuristic for "one garment, cleanly separated": a single instance
        /// that neither fills the frame (background not found) nor is a speck.
        public var looksLikeSingleGarment: Bool {
            instanceCount == 1 && coverage > 0.03 && coverage < 0.9
        }
    }

    public enum LiftError: Error, Equatable {
        case noSubject
        case renderFailed
    }

    public static func lift(_ image: CGImage) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try liftSync(image)
        }.value
    }

    static func liftSync(_ image: CGImage) throws -> Result {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw LiftError.noSubject
        }
        let instances = observation.allInstances
        let masked = try observation.generateMaskedImage(
            ofInstances: instances, from: handler, croppedToInstancesExtent: true
        )
        let mask = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)

        let context = CIContext()
        guard let cgImage = context.createCGImage(CIImage(cvPixelBuffer: masked), from: CIImage(cvPixelBuffer: masked).extent) else {
            throw LiftError.renderFailed
        }
        return Result(image: cgImage, coverage: meanValue(of: CIImage(cvPixelBuffer: mask), context: context), instanceCount: instances.count)
    }

    /// Mean of a single-channel mask = fraction of the frame that is subject.
    private static func meanValue(of mask: CIImage, context: CIContext) -> Double {
        let filter = CIFilter.areaAverage()
        filter.inputImage = mask
        filter.extent = mask.extent
        guard let output = filter.outputImage else { return 0 }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: nil
        )
        return Double(pixel[0])
    }
}
