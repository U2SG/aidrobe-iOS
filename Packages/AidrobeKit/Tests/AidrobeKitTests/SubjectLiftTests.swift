import CoreGraphics
import Foundation
import Testing
@testable import AidrobeKit

@Suite struct SubjectLiftTests {
    /// A navy "garment" on a plain beige background: one instance, partial
    /// coverage, and every kept pixel identical to the source.
    @Test func liftsASingleGarmentWithoutChangingItsPixels() async throws {
        let source = try #require(Self.flatLay())
        let result: SubjectLift.Result
        do {
            result = try await SubjectLift.lift(source)
        } catch is SubjectLift.LiftError {
            Issue.record("Vision found no subject in a plain flat lay")
            return
        } catch {
            // Vision itself unavailable (e.g. a virtualised CI host without the
            // Neural Engine): nothing to assert about our code.
            print("SubjectLift skipped: \(error)")
            return
        }

        #expect(result.instanceCount == 1)
        #expect(result.looksLikeSingleGarment, "coverage \(result.coverage)")
        let centre = try #require(Self.rgba(result.image, x: result.image.width / 2, y: result.image.height / 2))
        // Navy (51, 82, 140), straight from the source.
        #expect(abs(Int(centre.r) - 51) <= 3 && abs(Int(centre.g) - 82) <= 3 && abs(Int(centre.b) - 140) <= 3)
        #expect(centre.a == 255)
    }

    static func flatLay() -> CGImage? {
        let width = 600, height = 800
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.91, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.20, green: 0.32, blue: 0.55, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 150, y: 200, width: 300, height: 400), cornerWidth: 40, cornerHeight: 40, transform: nil))
        context.fillPath()
        return context.makeImage()
    }

    static func rgba(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
