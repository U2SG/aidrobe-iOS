import AidrobeKit
import Foundation
import UIKit

/// Photo → wardrobe item pipeline: compress, upload (presign), create an import
/// task with an idempotency key, poll recognition, then confirm. Unfinished
/// uploads can resume by ID and recognised imports are listed by the server.
@MainActor
@Observable
final class ImportFlowModel {
    struct Job: Identifiable {
        enum Phase {
            case uploading
            case recognising
            case needsConfirm(Wire.ImportTaskResponse)
            case interrupted
            case confirming
            case done(itemCount: Int)
            case failed(String)
        }

        let id: UUID
        var thumbnail: UIImage?
        var taskID: String?
        var phase: Phase

        var pendingTask: Wire.ImportTaskResponse? {
            guard case let .needsConfirm(task) = phase else { return nil }
            return task
        }
    }

    /// One candidate as edited on the confirm form.
    struct CandidateDraft: Identifiable {
        var id: String { tempItemID ?? "single" }
        let tempItemID: String?
        var include: Bool
        var title: String
        var category: String
        var color: String
        let imageURL: URL?
        let imageCaption: String
        let alreadyConfirmed: Bool
        let possibleDuplicates: [Wire.ImportDuplicateHint]
    }

    private(set) var jobs: [Job] = []
    private(set) var pendingError: String?
    private(set) var isLoadingPending = false
    private let api: APIClient
    private let uploader: PresignedUploader
    private let store: UserDefaults
    private let accountGeneration = AccountLocalData.generation
    static let pendingKey = "aidrobe.pendingImportTasks"

    init(api: APIClient, store: UserDefaults = .standard) {
        self.api = api
        self.uploader = PresignedUploader(api: api)
        self.store = store
    }

    // MARK: Start

    func importImages(
        _ images: [UIImage], source: Endpoints.ImportSourceType, input: Endpoints.ImportInputType = .image
    ) {
        for image in images {
            let job = Job(id: UUID(), thumbnail: image, phase: .uploading)
            jobs.append(job)
            Task { await run(job.id, image: image, source: source, input: input) }
        }
    }

    func loadPending() async {
        guard !isLoadingPending else { return }
        isLoadingPending = true
        pendingError = nil
        do {
            let pageSize = 20
            var offset = 0
            while true {
                try Task.checkCancellation()
                let tasks = try await api.send(Endpoints.pendingImportTasks(limit: pageSize, offset: offset))
                try Task.checkCancellation()
                for task in tasks {
                    if let index = jobs.firstIndex(where: { $0.taskID == task.taskId }) {
                        if case .interrupted = jobs[index].phase { jobs[index].phase = .needsConfirm(task) }
                    } else {
                        jobs.append(Job(id: UUID(), taskID: task.taskId, phase: .needsConfirm(task)))
                    }
                }
                if tasks.count < pageSize { break }
                offset += tasks.count
            }
        } catch {
            if !Task.isCancelled {
                pendingError = userMessage(for: error)
            }
        }
        isLoadingPending = false
        guard !Task.isCancelled else { return }
        await withTaskGroup(of: Void.self) { group in
            for taskID in pendingTaskIDs where !jobs.contains(where: { $0.taskID == taskID }) {
                let id = UUID()
                jobs.append(Job(id: id, taskID: taskID, phase: .recognising))
                group.addTask { await self.poll(id, taskID: taskID) }
            }
        }
    }

    func review(_ jobID: UUID, taskID: String) async -> Wire.ImportTaskResponse? {
        pendingError = nil
        do {
            let task = try await api.send(Endpoints.importTask(taskID))
            if task.status == "waiting_confirm" { return task }
            forget(taskID)
            jobs.removeAll { $0.id == jobID }
        } catch {
            pendingError = userMessage(for: error)
        }
        return nil
    }

    func resume(_ job: Job) async {
        guard let taskID = job.taskID,
              let current = jobs.first(where: { $0.id == job.id }),
              case .interrupted = current.phase else { return }
        update(job.id) { $0.phase = .recognising }
        await poll(job.id, taskID: taskID)
    }

    private func run(
        _ id: UUID, image: UIImage, source: Endpoints.ImportSourceType, input: Endpoints.ImportInputType
    ) async {
        guard let data = ImageCompressor.jpegData(from: image) else {
            return update(id) { $0.phase = .failed("图片无法读取") }
        }
        do {
            let upload = try await uploader.upload(data, fileName: "\(id.uuidString).jpg", contentType: "image/jpeg")
            guard accountGeneration == AccountLocalData.generation else { return }
            update(id) { $0.phase = .recognising }
            // The job id doubles as the idempotency key: a retried create
            // returns the same task instead of a duplicate.
            let task = try await api.send(Endpoints.createImport(
                imageURL: upload.fileURL.absoluteString,
                inputType: input,
                source: source,
                idempotencyKey: id.uuidString
            ))
            update(id) { $0.taskID = task.taskId }
            remember(task.taskId)
            await poll(id, taskID: task.taskId)
        } catch {
            update(id) { $0.phase = .failed(userMessage(for: error)) }
        }
    }

    private func poll(_ id: UUID, taskID: String) async {
        do {
            let outcome = try await ImportPolling.waitForRecognition { [api] in
                try await api.send(Endpoints.importTask(taskID))
            }
            switch outcome {
            case let .waitingConfirm(task) where task.status == "completed":
                forget(taskID)
                update(id) { $0.phase = .done(itemCount: 0) }
            case let .waitingConfirm(task):
                update(id) { $0.phase = .needsConfirm(task) }
            case let .failed(_, message):
                forget(taskID)
                update(id) { $0.phase = .failed(message ?? "没能识别这张照片，可以换一张试试") }
            case .timedOut:
                update(id) { $0.phase = .interrupted }
            }
        } catch {
            if let status = (error as? APIError)?.status, status == 404 {
                forget(taskID)
                jobs.removeAll { $0.id == id }
            } else {
                update(id) { $0.phase = .interrupted }
            }
        }
    }

    // MARK: Confirm

    func drafts(for task: Wire.ImportTaskResponse) -> [CandidateDraft] {
        let candidates = task.candidateItems?.isEmpty == false
            ? task.candidateItems ?? []
            : [task.candidateItem].compactMap { $0 }
        return candidates.map { candidate in
            CandidateDraft(
                tempItemID: candidate.tempItemId,
                include: candidate.possibleDuplicates?.isEmpty != false && (candidate.shouldImport ?? true),
                title: candidate.displayName ?? candidate.title,
                category: candidate.category,
                color: candidate.colorMain,
                imageURL: URL(string: candidate.cutoutImageUrl ?? candidate.cropImageUrl ?? candidate.originalImageUrl),
                imageCaption: candidate.cutoutImageUrl != nil ? "商品图"
                    : candidate.cropImageUrl != nil ? "原照裁剪" : "原照 · 暂无单品图",
                alreadyConfirmed: candidate.confirmedItemId != nil,
                possibleDuplicates: candidate.possibleDuplicates ?? []
            )
        }
    }

    /// Confirms selected candidates and dismisses the rest when submitted.
    func confirm(_ jobID: UUID, task: Wire.ImportTaskResponse, drafts: [CandidateDraft]) async -> Bool {
        let selected = drafts.filter { $0.include && !$0.alreadyConfirmed }
        update(jobID) { $0.phase = .confirming }
        do {
            if selected.count == 1, let draft = selected.first, draft.tempItemID == nil {
                _ = try await api.send(Endpoints.confirmImport(
                    taskID: task.taskId,
                    Wire.ConfirmImportRequest(title: draft.title, category: draft.category, colorMain: draft.color)
                ))
            } else {
                let items = selected.compactMap { draft -> Wire.ConfirmItemInput? in
                    guard let tempID = draft.tempItemID else { return nil }
                    return Wire.ConfirmItemInput(
                        tempItemId: tempID, title: draft.title, category: draft.category, colorMain: draft.color
                    )
                }
                // Unselected candidates are skipped when the review is submitted.
                _ = try await api.send(Endpoints.confirmImportItems(
                    taskID: task.taskId, Wire.ConfirmItemsRequest(items: items, dismissRemaining: true)
                ))
            }
            forget(task.taskId)
            if selected.isEmpty {
                jobs.removeAll { $0.id == jobID }
            } else {
                update(jobID) { $0.phase = .done(itemCount: selected.count) }
            }
            return true
        } catch {
            update(jobID) { $0.phase = .needsConfirm(task) }
            return false
        }
    }

    func cancel(_ jobID: UUID, task: Wire.ImportTaskResponse) async -> Bool {
        await confirm(jobID, task: task, drafts: [])
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private var pendingTaskIDs: [String] {
        guard accountGeneration == AccountLocalData.generation else { return [] }
        return store.stringArray(forKey: Self.pendingKey) ?? []
    }

    private func remember(_ taskID: String) {
        guard accountGeneration == AccountLocalData.generation else { return }
        store.set(Array(Set(pendingTaskIDs + [taskID])), forKey: Self.pendingKey)
    }

    private func forget(_ taskID: String) {
        guard accountGeneration == AccountLocalData.generation else { return }
        store.set(pendingTaskIDs.filter { $0 != taskID }, forKey: Self.pendingKey)
    }
}
