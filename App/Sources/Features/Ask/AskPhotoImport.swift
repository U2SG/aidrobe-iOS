import AidrobeKit
import SwiftUI
import UIKit

/// Photos sent in Ask become wardrobe imports. Each send is one card in the
/// timeline: recognition, the user's words applied as prefilled values, then a
/// review that writes to the wardrobe only when the user taps the button.
@MainActor
@Observable
final class AskPhotoImportModel {
    struct Photo: Identifiable {
        enum Phase {
            case uploading
            case recognising
            case applyingNote
            case interrupted
            case review(Wire.ImportTaskResponse)
            case confirming(Wire.ImportTaskResponse)
            case added([String])
            case failed(String)
        }

        let id: UUID
        /// Kept for a retry after a failed upload or recognition; restored photos have none.
        var image: UIImage?
        var taskID: String?
        var phase: Phase
        var drafts: [ImportPipeline.CandidateDraft] = []
        var noteFailed = false

        var isWorking: Bool {
            switch phase {
            case .uploading, .recognising, .applyingNote, .confirming: true
            default: false
            }
        }

        var task: Wire.ImportTaskResponse? {
            if case let .review(task) = phase { task } else { nil }
        }

        var isConfirming: Bool {
            if case .confirming = phase { true } else { false }
        }

        var isApplyingNote: Bool {
            if case .applyingNote = phase { true } else { false }
        }

        var addedNames: [String]? {
            if case let .added(names) = phase { names } else { nil }
        }
    }

    struct Batch: Identifiable {
        let id: UUID
        let createdAt: Date
        let note: String?
        let conversationID: String?
        var photos: [Photo]
        var failure: String?

        var selectedCount: Int {
            photos.filter { $0.task != nil }.flatMap(\.drafts).filter { $0.include && !$0.alreadyConfirmed }.count
        }
    }

    /// Editable from the card (drafts are bound directly).
    var batches: [Batch] = []
    private let pipeline: ImportPipeline
    private let wardrobe: WardrobeStore
    private let accountGeneration = AccountLocalData.generation
    private var epoch = UUID()

    init(api: APIClient, wardrobe: WardrobeStore) {
        pipeline = ImportPipeline(api: api)
        self.wardrobe = wardrobe
    }

    /// Imports the photos as outfit photos from the album. `note` is applied to
    /// the recognised candidates; `conversationID` links the tasks when the
    /// conversation already exists on the server.
    func send(_ images: [UIImage], note: String, conversationID: String?) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let batch = Batch(
            id: UUID(), createdAt: .now, note: note.isEmpty ? nil : note, conversationID: conversationID,
            photos: images.map { Photo(id: UUID(), image: $0, phase: .uploading) }
        )
        batches.append(batch)
        for photo in batch.photos {
            Task { await run(batch.id, photo.id) }
        }
    }

    /// Server tasks of a reopened conversation, one card per task (the server
    /// keeps no grouping). `createdAt` places them in the timeline. Re-reading
    /// the same conversation keeps the cards already on the page.
    func restore(_ tasks: [Wire.ImportTaskResponse], at createdAt: Date, keepingLocal: Bool) {
        if !keepingLocal { reset() }
        let known = Set(batches.flatMap(\.photos).compactMap(\.taskID))
        let restored = tasks.filter { !known.contains($0.taskId) }.map { task in
            var photo = Photo(id: UUID(), taskID: task.taskId, phase: .recognising)
            switch task.status {
            case "waiting_confirm":
                photo.phase = .review(task)
                photo.drafts = ImportPipeline.drafts(for: task)
            case "completed":
                photo.phase = .added(Self.confirmedNames(task))
            case "failed":
                photo.phase = .failed(task.errorMessage ?? ImportPipeline.recognitionFailed)
            default:
                break
            }
            return Batch(id: UUID(), createdAt: createdAt, note: nil, conversationID: nil, photos: [photo])
        }
        batches += restored
        for batch in restored {
            for photo in batch.photos where photo.isWorking {
                if let taskID = photo.taskID { Task { await poll(batch.id, photo.id, taskID: taskID) } }
            }
        }
    }

    func reset() {
        epoch = UUID()
        batches = []
    }

    func retry(_ batchID: UUID, _ photoID: UUID) async {
        guard let photo = photo(batchID, photoID) else { return }
        switch photo.phase {
        case .interrupted:
            guard let taskID = photo.taskID else { return }
            update(batchID, photoID) { $0.phase = .recognising }
            await poll(batchID, photoID, taskID: taskID)
        case .failed where photo.image != nil:
            update(batchID, photoID) {
                $0.phase = .uploading
                $0.taskID = nil
            }
            await run(batchID, photoID)
        default:
            break
        }
    }

    /// Confirms the chosen candidates of every reviewed photo in the card and
    /// dismisses the rest of those photos.
    func confirm(_ batchID: UUID, sendsPrice: Bool) async {
        guard let batch = batches.first(where: { $0.id == batchID }) else { return }
        let expectedEpoch = epoch
        updateBatch(batchID) { $0.failure = nil }
        var added = false
        for photo in batch.photos {
            guard let task = photo.task else { continue }
            update(batchID, photo.id) { $0.phase = .confirming(task) }
            do {
                try await pipeline.confirm(task, drafts: photo.drafts, sendsPrice: sendsPrice)
                guard isCurrent(expectedEpoch) else { return }
                let names = photo.drafts.filter { $0.include || $0.alreadyConfirmed }.map(\.title)
                added = added || !names.isEmpty
                update(batchID, photo.id) { $0.phase = .added(names) }
            } catch {
                guard isCurrent(expectedEpoch) else { return }
                update(batchID, photo.id) { $0.phase = .review(task) }
                updateBatch(batchID) { $0.failure = userMessage(for: error) }
            }
        }
        if added { await wardrobe.load() }
    }

    // MARK: Pipeline

    private func run(_ batchID: UUID, _ photoID: UUID) async {
        guard let image = photo(batchID, photoID)?.image,
              let conversationID = batches.first(where: { $0.id == batchID }).map(\.conversationID) else { return }
        let expectedEpoch = epoch
        do {
            // A fresh key per attempt: retrying a failed recognition needs a new task.
            let task = try await pipeline.start(
                image, key: UUID(), source: .album, input: .outfitImage, conversationID: conversationID,
                onUploaded: { [weak self] in
                    guard let self, self.isCurrent(expectedEpoch) else { throw CancellationError() }
                    self.update(batchID, photoID) { $0.phase = .recognising }
                }
            )
            guard isCurrent(expectedEpoch) else { return }
            update(batchID, photoID) { $0.taskID = task.taskId }
            await poll(batchID, photoID, taskID: task.taskId)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(expectedEpoch) else { return }
            update(batchID, photoID) { $0.phase = .failed(ImportPipeline.message(for: error)) }
        }
    }

    private func poll(_ batchID: UUID, _ photoID: UUID, taskID: String) async {
        let expectedEpoch = epoch
        do {
            let outcome = try await pipeline.waitForRecognition(taskID)
            guard isCurrent(expectedEpoch) else { return }
            switch outcome {
            case let .waitingConfirm(task) where task.status == "completed":
                update(batchID, photoID) { $0.phase = .added(Self.confirmedNames(task)) }
            case let .waitingConfirm(task):
                await review(batchID, photoID, task: task, expectedEpoch: expectedEpoch)
            case let .failed(_, message):
                update(batchID, photoID) { $0.phase = .failed(message ?? ImportPipeline.recognitionFailed) }
            case .timedOut:
                update(batchID, photoID) { $0.phase = .interrupted }
            }
        } catch {
            guard isCurrent(expectedEpoch) else { return }
            update(batchID, photoID) { $0.phase = .interrupted }
        }
    }

    /// Applies the user's words once, then opens the review. A failed note keeps
    /// the recognised values.
    private func review(_ batchID: UUID, _ photoID: UUID, task: Wire.ImportTaskResponse, expectedEpoch: UUID) async {
        var reviewed = task
        if let note = batches.first(where: { $0.id == batchID })?.note {
            update(batchID, photoID) { $0.phase = .applyingNote }
            do {
                reviewed = try await pipeline.api.send(Endpoints.applyImportNote(taskID: task.taskId, note: note))
            } catch {
                guard isCurrent(expectedEpoch) else { return }
                update(batchID, photoID) { $0.noteFailed = true }
            }
            guard isCurrent(expectedEpoch) else { return }
        }
        update(batchID, photoID) {
            $0.phase = .review(reviewed)
            $0.drafts = ImportPipeline.drafts(for: reviewed)
        }
    }

    // MARK: Helpers

    private static func confirmedNames(_ task: Wire.ImportTaskResponse) -> [String] {
        ImportPipeline.candidates(of: task).filter { $0.confirmedItemId != nil }.map { $0.displayName ?? $0.title }
    }

    private func photo(_ batchID: UUID, _ photoID: UUID) -> Photo? {
        batches.first { $0.id == batchID }?.photos.first { $0.id == photoID }
    }

    private func updateBatch(_ batchID: UUID, _ change: (inout Batch) -> Void) {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else { return }
        change(&batches[index])
    }

    private func update(_ batchID: UUID, _ photoID: UUID, _ change: (inout Photo) -> Void) {
        updateBatch(batchID) { batch in
            guard let index = batch.photos.firstIndex(where: { $0.id == photoID }) else { return }
            change(&batch.photos[index])
        }
    }

    private func isCurrent(_ expectedEpoch: UUID) -> Bool {
        epoch == expectedEpoch && accountGeneration == AccountLocalData.generation
    }
}

/// One send of photos in the Ask timeline.
struct AskPhotoImportCard: View {
    @Bindable var model: AskPhotoImportModel
    let batchID: UUID
    let showsPrice: Bool

    var body: some View {
        if let index = model.batches.firstIndex(where: { $0.id == batchID }) {
            content($model.batches[index])
        }
    }

    private func content(_ batch: Binding<AskPhotoImportModel.Batch>) -> some View {
        let photos = batch.wrappedValue.photos
        let working = photos.filter { $0.isWorking && !$0.isConfirming }
        let reviewing = photos.contains { $0.task != nil || $0.isConfirming }
        let isConfirming = photos.contains(where: \.isConfirming)
        let added = photos.flatMap { $0.addedNames ?? [] }
        return VStack(alignment: .leading, spacing: Spacing.row) {
            SectionHeading(title: "从照片添加")
            if let note = batch.wrappedValue.note {
                Text(note)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.label)
            }
            if !working.isEmpty {
                HStack(spacing: Spacing.tight) {
                    ProgressView()
                    Text(working.allSatisfy(\.isApplyingNote) ? "正在按你的话整理…" : "正在识别 \(working.count) 张照片…")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
            }
            ForEach(batch.photos) { $photo in
                photoSection($photo)
            }
            if !added.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Label("已加入 \(added.count) 件", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.success)
                    Text(added.joined(separator: "、"))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                .accessibilityElement(children: .combine)
            } else if photos.allSatisfy({ $0.addedNames != nil }) {
                Text("这次没有加入衣物。")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }
            if let failure = batch.wrappedValue.failure {
                Text(failure).font(.subheadline).foregroundStyle(Color.secondaryLabel)
            }
            if reviewing {
                let count = batch.wrappedValue.selectedCount
                Button {
                    Task { await model.confirm(batchID, sendsPrice: showsPrice) }
                } label: {
                    Group {
                        if isConfirming { ProgressView() } else { Text("加入衣橱（\(count) 件）") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(isConfirming || count == 0 || hasEmptyTitle(photos))
                .accessibilityIdentifier("ask.import.confirm")
            }
        }
    }

    @ViewBuilder
    private func photoSection(_ photo: Binding<AskPhotoImportModel.Photo>) -> some View {
        let value = photo.wrappedValue
        switch value.phase {
        case .review, .confirming:
            if value.noteFailed {
                Text("没能按你的话调整，可以手动改")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryLabel)
            }
            ForEach(photo.drafts) { $draft in
                if !draft.alreadyConfirmed {
                    CandidateRow(draft: $draft, showsPrice: showsPrice)
                        .disabled(value.task == nil)
                }
            }
        case let .failed(message):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.control) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if value.image != nil {
                    Button("重试") { Task { await model.retry(batchID, value.id) } }
                        .buttonStyle(.glass)
                }
            }
        case .interrupted:
            Button("继续查看识别进度") { Task { await model.retry(batchID, value.id) } }
                .buttonStyle(.glass)
        case .uploading, .recognising, .applyingNote, .added:
            EmptyView()
        }
    }

    private func hasEmptyTitle(_ photos: [AskPhotoImportModel.Photo]) -> Bool {
        photos.filter { $0.task != nil }.flatMap(\.drafts).contains {
            $0.include && !$0.alreadyConfirmed && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// One recognised garment: the photo crop, editable fields and whether to add it.
private struct CandidateRow: View {
    @Binding var draft: ImportPipeline.CandidateDraft
    let showsPrice: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.control) {
            GarmentImage(url: draft.photoURL, forceOriginal: true, fit: true)
                .frame(width: 72, height: 90)
                .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.tile))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.separator))
                .opacity(draft.include ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("名称", text: $draft.title)
                        .font(.body)
                        .foregroundStyle(Color.label)
                    Toggle("加入", isOn: $draft.include)
                        .labelsHidden()
                        .accessibilityLabel("加入\(draft.title)")
                }
                Group {
                    HStack(spacing: Spacing.tight) {
                        Picker("类别", selection: $draft.category) {
                            if !Garment.categories.contains(draft.category) {
                                Text(Garment.category(draft.category)).tag(draft.category)
                            }
                            ForEach(Garment.categories, id: \.self) { Text(Garment.category($0)).tag($0) }
                        }
                        Picker("主色", selection: $draft.color) {
                            if Garment.swatch(draft.color) == nil { Text(draft.color).tag(draft.color) }
                            ForEach(Garment.colors, id: \.key) { Text($0.label).tag($0.key) }
                        }
                    }
                    HStack(spacing: Spacing.tight) {
                        Picker("材质", selection: $draft.material) {
                            if !Garment.materials.contains(where: { $0.key == draft.material }) {
                                Text(draft.material.isEmpty ? "材质未知" : draft.material).tag(draft.material)
                            }
                            ForEach(Garment.materials, id: \.key) { Text($0.label).tag($0.key) }
                        }
                        if showsPrice {
                            HStack(spacing: 2) {
                                Text("¥").foregroundStyle(Color.secondaryLabel)
                                TextField("价格", text: $draft.price)
                                    .keyboardType(.decimalPad)
                                    .frame(maxWidth: 80)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .pickerStyle(.menu)
                .font(.subheadline)
                .tint(Color.secondaryLabel)
                .disabled(!draft.include)
                if draft.partiallyHidden {
                    Label("被外套挡住了大半，不会生成单品图。想要完整的单品图，可以单独拍一张。", systemImage: "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if let match = draft.possibleDuplicates.first {
                    Label("可能已在衣橱：\(match.title)", systemImage: "square.on.square")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
            }
        }
    }
}
