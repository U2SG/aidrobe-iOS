import AidrobeKit
import Foundation
import UIKit

/// Photo → wardrobe item pipeline: compress, upload (presign), create an import
/// task with an idempotency key, poll recognition, then confirm. Task ids that
/// are recognised but not yet confirmed are persisted, so a restart resumes
/// them instead of losing the work (the backend has no "list my tasks" API).
@MainActor
@Observable
final class ImportFlowModel {
    struct Job: Identifiable {
        enum Phase {
            case uploading
            case recognising
            case needsConfirm(Wire.ImportTaskResponse)
            case confirming
            case done(itemCount: Int)
            case failed(String)
        }

        let id: UUID
        var thumbnail: UIImage?
        var taskID: String?
        var phase: Phase
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
        let alreadyConfirmed: Bool
    }

    private(set) var jobs: [Job] = []
    private let api: APIClient
    private let uploader: PresignedUploader
    private let store: UserDefaults
    private static let pendingKey = "aidrobe.pendingImportTasks"

    init(api: APIClient, store: UserDefaults = .standard) {
        self.api = api
        self.uploader = PresignedUploader(api: api)
        self.store = store
    }

    var pendingConfirmCount: Int {
        jobs.filter { if case .needsConfirm = $0.phase { true } else { false } }.count
    }

    var isBusy: Bool {
        jobs.contains {
            switch $0.phase {
            case .uploading, .recognising, .confirming: true
            default: false
            }
        }
    }

    // MARK: Start

    func importImages(_ images: [UIImage], source: Endpoints.ImportSourceType) {
        for image in images {
            let job = Job(id: UUID(), thumbnail: image, phase: .uploading)
            jobs.append(job)
            Task { await run(job.id, image: image, source: source) }
        }
    }

    /// Re-attaches tasks that were recognised but not confirmed before a restart.
    func resumePending() async {
        for taskID in pendingTaskIDs where !jobs.contains(where: { $0.taskID == taskID }) {
            let id = UUID()
            jobs.append(Job(id: id, taskID: taskID, phase: .recognising))
            await poll(id, taskID: taskID)
        }
    }

    private func run(_ id: UUID, image: UIImage, source: Endpoints.ImportSourceType) async {
        guard let data = ImageCompressor.jpegData(from: image) else {
            return update(id) { $0.phase = .failed("图片无法读取") }
        }
        do {
            let upload = try await uploader.upload(data, fileName: "\(id.uuidString).jpg", contentType: "image/jpeg")
            update(id) { $0.phase = .recognising }
            // The job id doubles as the idempotency key: a retried create
            // returns the same task instead of a duplicate.
            let task = try await api.send(Endpoints.createImport(
                imageURL: upload.fileURL.absoluteString,
                inputType: .image,
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
                update(id) { $0.phase = .failed("识别时间过长，稍后会在这里继续") }
            }
        } catch {
            update(id) { $0.phase = .failed(userMessage(for: error)) }
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
                include: candidate.shouldImport ?? true,
                title: candidate.displayName ?? candidate.title,
                category: candidate.category,
                color: candidate.colorMain,
                imageURL: URL(string: candidate.cropImageUrl ?? candidate.originalImageUrl),
                alreadyConfirmed: candidate.confirmedItemId != nil
            )
        }
    }

    /// Confirms the selected candidates. Multi-candidate tasks go through
    /// confirm-items so a partial selection can be completed later.
    func confirm(_ jobID: UUID, task: Wire.ImportTaskResponse, drafts: [CandidateDraft]) async -> Bool {
        let selected = drafts.filter { $0.include && !$0.alreadyConfirmed }
        guard !selected.isEmpty else { return false }
        update(jobID) { $0.phase = .confirming }
        do {
            if (task.candidateItems?.count ?? 0) <= 1 {
                let draft = selected[0]
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
                // The form lists every candidate, so an unchecked one is a
                // deliberate "not this": close the task instead of leaving it open.
                _ = try await api.send(Endpoints.confirmImportItems(
                    taskID: task.taskId, Wire.ConfirmItemsRequest(items: items, dismissRemaining: true)
                ))
            }
            forget(task.taskId)
            update(jobID) { $0.phase = .done(itemCount: selected.count) }
            return true
        } catch {
            update(jobID) { $0.phase = .needsConfirm(task) }
            return false
        }
    }

    func dismissFinished() {
        jobs.removeAll {
            switch $0.phase {
            case .done, .failed: true
            default: false
            }
        }
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private var pendingTaskIDs: [String] {
        store.stringArray(forKey: Self.pendingKey) ?? []
    }

    private func remember(_ taskID: String) {
        store.set(Array(Set(pendingTaskIDs + [taskID])), forKey: Self.pendingKey)
    }

    private func forget(_ taskID: String) {
        store.set(pendingTaskIDs.filter { $0 != taskID }, forKey: Self.pendingKey)
    }
}
