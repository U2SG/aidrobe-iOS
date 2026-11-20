import AidrobeKit
import CoreML
import Photos
import UIKit
import Vision

/// A user album and how many photos and videos it holds.
struct AlbumInfo: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let count: Int
}

/// A photo that passed the on-device screening, ready to upload.
struct ScreenedPhoto: Sendable {
    let id: String
    /// Calendar day the photo was taken (`YYYY-MM-DD`).
    let day: String
    let jpeg: Data
}

struct ScreeningResult: Sendable {
    var kept: [ScreenedPhoto] = []
    var skipped: [(id: String, reason: AlbumScan.SkipReason)] = []
    /// Vision could not run (the simulator lacks some models); photos were kept unscreened.
    var visionUnavailable = false
}

/// PhotoKit and Vision for the album scan. Everything here runs on the phone
/// and costs nothing; it decides which photos are worth sending for recognition.
enum AlbumLibrary {
    static var hasFullAccess: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Albums the user made, by name; smart albums such as Recents are not offered.
    static func albums() -> [AlbumInfo] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        var albums: [AlbumInfo] = []
        collections.enumerateObjects { collection, _, _ in
            albums.append(AlbumInfo(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "未命名相册",
                count: PHAsset.fetchAssets(in: collection, options: nil).count
            ))
        }
        return albums
    }

    static func album(_ id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Asset ids in the album, newest first; nil when the album is gone.
    static func assetIDs(in albumID: String) -> [String]? {
        guard let album = album(albumID) else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(in: album, options: options)
        var ids: [String] = []
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    // MARK: Screening

    /// Screens photos in order: file facts first (video, screenshot, size), then
    /// people and clothes with Vision, then near-duplicates of the same day.
    /// `reinclude` photos were brought back by the user and skip the judgement calls.
    static func screen(
        _ ids: [String], reinclude: Set<String>, progress: @escaping @Sendable (Int) -> Void
    ) async -> ScreeningResult {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }

        var result = ScreeningResult()
        var candidates: [(photo: ScreenedPhoto, quality: Double, print: VNFeaturePrintObservation?)] = []
        for (index, id) in ids.enumerated() {
            defer { progress(index + 1) }
            if Task.isCancelled { break }
            guard let asset = byID[id] else {
                result.skipped.append((id, .unreadable))
                continue
            }
            if let reason = fileReason(asset) {
                result.skipped.append((id, reason))
                continue
            }
            guard let image = await loadImage(asset),
                  let jpeg = ImageCompressor.jpegData(from: image),
                  let cgImage = UIImage(data: jpeg)?.cgImage else {
                result.skipped.append((id, .unreadable))
                continue
            }
            let photo = ScreenedPhoto(id: id, day: AlbumScan.day(of: asset.creationDate ?? .now), jpeg: jpeg)
            if reinclude.contains(id) {
                result.kept.append(photo)
                continue
            }
            let look = inspect(cgImage)
            if look.visionUnavailable { result.visionUnavailable = true }
            if let reason = look.skip {
                result.skipped.append((id, reason))
                continue
            }
            let quality = sharpness(cgImage) * Double(asset.pixelWidth * asset.pixelHeight)
            candidates.append((photo, quality, look.print))
        }

        func distance(_ i: Int, _ j: Int) -> Float? {
            guard let a = candidates[i].print, let b = candidates[j].print else { return nil }
            var distance: Float = 0
            return (try? a.computeDistance(&distance, to: b)) != nil ? distance : nil
        }
        var dropped: Set<Int> = []
        if AlbumScan.printsAreDegenerate(count: candidates.count, distance: distance) {
            result.visionUnavailable = true
        } else {
            let shots = candidates.map { AlbumScan.Shot(day: $0.photo.day, quality: $0.quality) }
            dropped = AlbumScan.nearDuplicates(shots, distance: distance)
        }
        for (index, candidate) in candidates.enumerated() {
            if dropped.contains(index) {
                result.skipped.append((candidate.photo.id, .duplicate))
            } else {
                result.kept.append(candidate.photo)
            }
        }
        return result
    }

    private static func fileReason(_ asset: PHAsset) -> AlbumScan.SkipReason? {
        if asset.mediaSubtypes.contains(.photoScreenshot) || asset.mediaSubtypes.contains(.videoScreenRecording) {
            return .screenshot
        }
        if asset.mediaType != .image { return .video }
        if min(asset.pixelWidth, asset.pixelHeight) < AlbumScan.minShortSide { return .tooSmall }
        return nil
    }

    private static func loadImage(_ asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        let edge = ImageCompressor.maxLongEdge
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: edge, height: edge), contentMode: .aspectFit, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private struct Look {
        var skip: AlbumScan.SkipReason?
        var print: VNFeaturePrintObservation?
        var visionUnavailable = false
    }

    /// People count, clothes for photos without anyone, and a feature print of
    /// the person (or the whole photo) for near-duplicate checks. A request
    /// Vision can't run keeps the photo: missing a check must not lose it.
    private static func inspect(_ image: CGImage) -> Look {
        var look = Look()
        let handler = VNImageRequestHandler(cgImage: image)
        let humans = onCPUInSimulator(VNDetectHumanRectanglesRequest())
        humans.upperBodyOnly = false
        var people: [VNHumanObservation]?
        do {
            try handler.perform([humans])
            people = humans.results ?? []
        } catch {
            look.visionUnavailable = true
        }
        if let people {
            let areas = people.map { Double($0.boundingBox.width * $0.boundingBox.height) }
            let count = AlbumScan.prominentPeople(boxAreas: areas)
            if count >= 2 { look.skip = .multiplePeople; return look }
            if count == 0 {
                let classify = onCPUInSimulator(VNClassifyImageRequest())
                do {
                    try handler.perform([classify])
                    let clothes = (classify.results ?? []).contains {
                        $0.confidence >= AlbumScan.garmentConfidence && AlbumScan.garmentLabels.contains($0.identifier)
                    }
                    if !clothes { look.skip = .noGarment; return look }
                } catch {
                    look.visionUnavailable = true
                }
            }
        }
        // Mirror selfies share the room; printing only the person tells outfits apart.
        let printRequest = onCPUInSimulator(VNGenerateImageFeaturePrintRequest())
        if let person = people?.max(by: { area($0.boundingBox) < area($1.boundingBox) })?.boundingBox {
            printRequest.regionOfInterest = person
                .insetBy(dx: -person.width * 0.1, dy: -person.height * 0.05)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        do {
            try handler.perform([printRequest])
            look.print = printRequest.results?.first
        } catch {
            look.visionUnavailable = true
        }
        return look
    }

    /// The simulator has no Neural Engine or GPU path for Vision's models; run them on the CPU there.
    private static func onCPUInSimulator<Request: VNRequest>(_ request: Request) -> Request {
        #if targetEnvironment(simulator)
        for (stage, devices) in (try? request.supportedComputeStageDevices) ?? [:] {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
        return request
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// Laplacian variance of a 256 px grayscale copy.
    private static func sharpness(_ image: CGImage) -> Double {
        let scale = 256 / CGFloat(max(image.width, image.height))
        let width = max(3, Int(CGFloat(image.width) * min(1, scale)))
        let height = max(3, Int(CGFloat(image.height) * min(1, scale)))
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? AlbumScan.sharpness(gray: gray, width: width, height: height) : 0
    }
}
