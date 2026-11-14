import AidrobeKit
import CryptoKit
import SwiftUI
import UIKit

/// A garment picture ready to draw. `isCutout` means the background is gone, so
/// the piece can sit straight on the page instead of inside a photo tile.
struct GarmentRender: Sendable {
    let image: UIImage
    let isCutout: Bool
}

/// Loads garment photos and, when asked, lifts the garment off its background
/// on device (Apple Vision). The photo never leaves the phone for this, the
/// original stays on the server, and results are cached on disk by image path —
/// signed URLs rotate, paths don't.
actor GarmentImagePipeline {
    static let shared = GarmentImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private var failedCutouts: Set<String> = []
    private var lifting: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: "garment-cutouts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    func render(_ url: URL, cutout: Bool) async -> GarmentRender? {
        let key = url.path()
        if cutout, !failedCutouts.contains(key) {
            if let lifted = memory.object(forKey: "cutout:\(key)" as NSString) {
                return GarmentRender(image: lifted, isCutout: true)
            }
            let file = directory.appending(path: Self.fileName(for: key))
            if let lifted = UIImage(contentsOfFile: file.path()) {
                memory.setObject(lifted, forKey: "cutout:\(key)" as NSString)
                return GarmentRender(image: lifted, isCutout: true)
            }
            guard let original = await original(url, key: key) else { return nil }
            // Several views ask for the same garment at once; lift it once.
            let task = lifting[key] ?? Task { await Self.liftSubject(from: original) }
            lifting[key] = task
            let lifted = await task.value
            lifting[key] = nil
            if let lifted {
                try? lifted.pngData()?.write(to: file, options: .atomic)
                memory.setObject(lifted, forKey: "cutout:\(key)" as NSString)
                return GarmentRender(image: lifted, isCutout: true)
            }
            failedCutouts.insert(key)
            return GarmentRender(image: original, isCutout: false)
        }
        return await original(url, key: key).map { GarmentRender(image: $0, isCutout: false) }
    }

    private func original(_ url: URL, key: String) async -> UIImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = Self.downsample(data, maxPixel: 1200) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// The garment lifted off its background, or nil when Vision finds nothing
    /// usable: no subject, a speck, or a "subject" that is the whole frame.
    /// A pair of shoes is two instances, so instance count is not a criterion.
    private static func liftSubject(from image: UIImage) async -> UIImage? {
        guard let source = image.cgImage, let lift = try? await SubjectLift.lift(source),
              lift.coverage > 0.03, lift.coverage < 0.9 else { return nil }
        return UIImage(cgImage: lift.image)
    }
}

/// Garment picture that fills its frame: a cutout floats with breathing room,
/// an untouched photo fills a rounded tile.
struct GarmentImage: View {
    let url: URL?
    var forceOriginal = false
    var fit = false
    var photoAspectRatio: CGFloat?
    @AppStorage(Preferences.cutoutKey) private var prefersCutout = true
    @State private var render: GarmentRender?

    var body: some View {
        picture
            .task(id: TaskKey(url: url, cutout: prefersCutout && !forceOriginal)) {
                guard let url else { return render = nil }
                render = await GarmentImagePipeline.shared.render(url, cutout: prefersCutout && !forceOriginal)
            }
            .animation(.easeOut(duration: 0.2), value: render?.isCutout)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var picture: some View {
        let image = GarmentPicture(render: render, fit: fit)
        if let fallback = photoAspectRatio {
            let size = render?.image.size
            let ratio = size.flatMap { $0.height > 0 ? $0.width / $0.height : nil } ?? fallback
            image.aspectRatio(ratio, contentMode: .fit)
        } else {
            image
        }
    }

    private struct TaskKey: Equatable {
        let url: URL?
        let cutout: Bool
    }
}

/// The same tile treatment for live pictures and snapshots rendered for sharing.
struct GarmentPicture: View {
    let render: GarmentRender?
    var fit = false

    var body: some View {
        Color.clear
            .overlay {
                if let render {
                    if render.isCutout {
                        Image(uiImage: render.image)
                            .resizable()
                            .scaledToFit()
                            .padding(Spacing.tight)
                    } else {
                        Image(uiImage: render.image)
                            .resizable()
                            .aspectRatio(contentMode: fit ? .fit : .fill)
                    }
                }
            }
            .background((render?.isCutout ?? false) ? Color.clear : Color.fill)
            .clipShape(.rect(cornerRadius: Radius.tile))
            .accessibilityHidden(true)
    }
}

/// Records kept only on this device that belong to the signed-in account.
/// They go when the account signs out or its data is cleared, so the next
/// account on the device never sees them.
enum AccountLocalData {
    static let purchaseHistoryKey = "aidrobe.shopping.asked"
    static let wornTodayKey = "aidrobe.today.worn"
    static let placeNameKey = "aidrobe.settings.placeName"

    @MainActor private(set) static var generation = UUID()

    @MainActor static func clear() {
        generation = UUID()
        for key in [purchaseHistoryKey, wornTodayKey, placeNameKey, ImportFlowModel.pendingKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

enum Preferences {
    static let cutoutKey = "aidrobe.display.cutout"
    static let appearanceKey = "aidrobe.display.appearance"

    /// Stored as "system" / "light" / "dark".
    static func colorScheme(_ raw: String) -> ColorScheme? {
        switch raw {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
