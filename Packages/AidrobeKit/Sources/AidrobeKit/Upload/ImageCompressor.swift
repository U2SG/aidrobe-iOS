#if canImport(UIKit)
import UIKit

/// Matches the RN client: long edge ≤ 1600 px, JPEG quality 0.8.
public enum ImageCompressor {
    public static let maxLongEdge: CGFloat = 1600
    public static let quality: CGFloat = 0.8

    public static func jpegData(from image: UIImage) -> Data? {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, maxLongEdge / longEdge)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
#endif
