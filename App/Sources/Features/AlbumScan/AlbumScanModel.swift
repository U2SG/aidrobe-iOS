import AidrobeKit
import Foundation
import Photos

/// Album scan: screen the chosen album on the phone, upload what passes as one
/// batch, wait for the backend to merge garments across photos, then apply the
/// user's create / link / skip choices per garment.
@MainActor
@Observable
final class AlbumScanModel {
    enum Phase {
        case starting
        case noAccess(limited: Bool)
        /// Who-is-in-the-photo notice; must be confirmed before choosing an album.
        case notice
        case albums([AlbumInfo])
        /// The remembered album, ready to scan again.
        case ready(unseen: Int)
        case screening(done: Int, total: Int)
        case uploading(done: Int, total: Int)
        /// Nothing new passed the screening; nothing was sent.
        case nothingToSend
        case recognising(Wire.ImportBatchResponse?)
        case review(Wire.ImportBatchResponse)
        case saving(Wire.ImportBatchResponse)
        case finished(added: Int, wears: Int)
        case failed(String)
    }

    /// One garment as the user is deciding it.
    struct Draft {
        var choice: AlbumScan.Choice
        var backfill = true
        var title: String
        var category: String
        var color: String
    }

    nonisolated static let ledgerKey = "aidrobe.albumScan.ledger"

    private(set) var phase: Phase = .starting
    private(set) var ledger: AlbumScan.Ledger
    private(set) var visionUnavailable = false
    private(set) var uploadFailures = 0
    var drafts: [String: Draft] = [:]
    var notice: String?
    private let api: APIClient
    private let uploader: PresignedUploader
    private let accountGeneration = AccountLocalData.generation
    /// The running scan (screening + uploads); outlives the page, cancelled at sign-out.
    private var work: Task<Void, Never>?

    /// Requests go out with whoever is signed in now; never send one account's photos to another.
    private var isCurrentAccount: Bool { accountGeneration == AccountLocalData.generation }

    init(api: APIClient) {
        self.api = api
        self.uploader = PresignedUploader(api: api)
        self.ledger = Self.loadLedger()
    }

    var albumTitle: String { ledger.albumTitle ?? "相册" }

    // MARK: Ledger

    nonisolated static func loadLedger() -> AlbumScan.Ledger {
        UserDefaults.standard.data(forKey: ledgerKey)
            .flatMap { try? JSONDecoder().decode(AlbumScan.Ledger.self, from: $0) } ?? AlbumScan.Ledger()
    }

    private func save() {
        guard accountGeneration == AccountLocalData.generation else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(ledger), forKey: Self.ledgerKey)
    }

    /// New photos in the remembered album, for the prompt on the add-garment sheet.
    nonisolated static func unseenInRememberedAlbum() -> (title: String, count: Int)? {
        let ledger = loadLedger()
        guard AlbumLibrary.hasFullAccess, let id = ledger.albumID,
              let ids = AlbumLibrary.assetIDs(in: id) else { return nil }
        return (ledger.albumTitle ?? "相册", AlbumScan.unseenCount(ids, processed: ledger.processed))
    }

    nonisolated static var hasPendingReview: Bool { loadLedger().pendingBatchID != nil }

    // MARK: Flow

    func start() async {
        // Reopened while a scan runs: keep showing its progress.
        guard work == nil, isCurrentAccount else { return }
        if ledger.pendingBatchID != nil { return phase = .recognising(nil) }
        // Scanning needs the whole library: limited access can't see a chosen album.
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await AlbumLibrary.requestAccess() }
        guard status == .authorized else { return phase = .noAccess(limited: status == .limited) }
        if let id = ledger.albumID, let ids = AlbumLibrary.assetIDs(in: id) {
            phase = .ready(unseen: AlbumScan.unseenCount(ids, processed: ledger.processed))
        } else {
            phase = .notice
        }
    }

    func acceptNotice() {
        phase = .albums(AlbumLibrary.albums())
    }

    func chooseAnotherAlbum() {
        phase = .notice
    }

    /// Starts one scan unless one is already running.
    func startScan(_ album: AlbumInfo? = nil) {
        guard work == nil, isCurrentAccount else { return }
        work = Task {
            if let album { await scan(album) } else { await scan() }
            work = nil
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    private func scan(_ album: AlbumInfo) async {
        if ledger.albumID != album.id {
            ledger.albumID = album.id
            ledger.albumTitle = album.title
            save()
        }
        await scan()
    }

    /// One run: screen up to 60 unseen photos, upload the rest as a new batch.
    private func scan() async {
        guard let albumID = ledger.albumID, let ids = AlbumLibrary.assetIDs(in: albumID) else {
            return phase = .notice
        }
        let run = AlbumScan.nextRun(newestFirst: ids, processed: ledger.processed, reinclude: ledger.reinclude)
        guard !run.isEmpty else { return phase = .ready(unseen: 0) }
        ledger.startRun()
        uploadFailures = 0
        phase = .screening(done: 0, total: run.count)
        let total = run.count
        let reinclude = ledger.reinclude
        let result = await Task.detached(priority: .userInitiated) {
            await AlbumLibrary.screen(run, reinclude: reinclude) { done in
                Task { @MainActor in
                    guard case .screening = self.phase else { return }
                    self.phase = .screening(done: done, total: total)
                }
            }
        }.value
        guard isCurrentAccount, !Task.isCancelled else { return }
        visionUnavailable = result.visionUnavailable
        for skip in result.skipped { ledger.skip(skip.id, skip.reason) }
        save()
        guard !result.kept.isEmpty else { return phase = .nothingToSend }
        await upload(result.kept)
    }

    /// The batch id is saved only once a photo is on the server, so reopening
    /// the page polls a batch that exists; until then the running task owns it.
    private func upload(_ photos: [ScreenedPhoto]) async {
        let batchID = UUID().uuidString.lowercased()
        phase = .uploading(done: 0, total: photos.count)
        var done = 0
        var sent = 0
        await withTaskGroup(of: (String, Bool).self) { group in
            var queue = photos.makeIterator()
            func next() {
                guard let photo = queue.next() else { return }
                group.addTask { [api, uploader] in
                    do {
                        guard await self.mayContinue() else { return (photo.id, false) }
                        let key = UUID().uuidString
                        let upload = try await uploader.upload(photo.jpeg, fileName: "\(key).jpg", contentType: "image/jpeg")
                        guard await self.mayContinue() else { return (photo.id, false) }
                        _ = try await api.send(Endpoints.createImport(
                            imageURL: upload.fileURL.absoluteString, inputType: .outfitImage, source: .album,
                            idempotencyKey: key, batchID: batchID, takenAt: photo.day
                        ))
                        return (photo.id, true)
                    } catch {
                        return (photo.id, false)
                    }
                }
            }
            for _ in 0..<3 { next() }
            for await (id, ok) in group {
                guard mayContinue() else { continue }
                done += 1
                if ok {
                    sent += 1
                    ledger.done(id)
                    if ledger.pendingBatchID == nil { ledger.pendingBatchID = batchID }
                    save()
                } else {
                    uploadFailures += 1
                }
                phase = .uploading(done: done, total: photos.count)
                next()
            }
        }
        guard mayContinue() else { return }
        guard sent > 0 else { return phase = .failed("照片没能上传，请检查网络后再试") }
        phase = .recognising(nil)
    }

    private func mayContinue() -> Bool { isCurrentAccount && !Task.isCancelled }

    /// Polls every 4 s while the page is open; the backend compares garments in the background.
    func waitForResults() async {
        guard let batchID = ledger.pendingBatchID else { return }
        while mayContinue() {
            do {
                let batch = try await api.send(Endpoints.importBatch(batchID))
                if batch.complete {
                    return show(batch)
                }
                phase = .recognising(batch)
            } catch {
                if (error as? APIError)?.status == 404 {
                    // No photo of the batch reached the server; start over.
                    finishBatch()
                    return await start()
                }
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func show(_ batch: Wire.ImportBatchResponse) {
        for group in batch.groups where drafts[group.groupId] == nil {
            drafts[group.groupId] = Draft(
                choice: AlbumScan.defaultChoice(kind: group.kind.rawValue, hasExistingItem: group.existingItem != nil),
                title: group.title,
                category: group.category,
                color: group.colorMain
            )
        }
        phase = .review(batch)
    }

    func bringBack(_ reason: AlbumScan.SkipReason) {
        ledger.bringBack(reason)
        save()
        if case .ready = phase, let id = ledger.albumID, let ids = AlbumLibrary.assetIDs(in: id) {
            phase = .ready(unseen: AlbumScan.unseenCount(ids, processed: ledger.processed))
        }
        notice = "下次扫描会加回这些照片"
    }

    // MARK: Confirm

    /// Returns true when the wardrobe changed.
    func confirm(_ batch: Wire.ImportBatchResponse) async -> Bool {
        guard isCurrentAccount else { return false }
        let decisions: [Wire.ImportBatchGroupDecision] = batch.groups.compactMap { group in
            guard group.status != .confirmed, let draft = drafts[group.groupId] else { return nil }
            switch draft.choice {
            case .create:
                return .init(
                    groupId: group.groupId, action: .create,
                    title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    category: draft.category, colorMain: draft.color
                )
            case .link:
                return .init(groupId: group.groupId, action: .link, backfillWear: draft.backfill)
            case .skip:
                return .init(groupId: group.groupId, action: .skip)
            }
        }
        guard let batchID = ledger.pendingBatchID else { return false }
        guard !decisions.isEmpty else {
            finishBatch()
            phase = .finished(added: 0, wears: 0)
            return false
        }
        phase = .saving(batch)
        do {
            let result = try await api.send(Endpoints.confirmImportBatch(batchID, .init(groups: decisions)))
            finishBatch()
            let added = result.groups.filter { $0.created == true }.count
            let wears = result.groups.reduce(0) { $0 + ($1.wearsRecorded ?? 0) }
            phase = .finished(added: added, wears: wears)
            return result.groups.contains { $0.action != .skip }
        } catch {
            if let reason = (error as? APIError)?.reason, ["unknown_group", "group_confirmed"].contains(reason) {
                notice = "结果有更新，请再看一遍"
                drafts = [:]
                phase = .recognising(nil)
            } else {
                notice = userMessage(for: error)
                phase = .review(batch)
            }
            return false
        }
    }

    private func finishBatch() {
        ledger.pendingBatchID = nil
        save()
    }
}
