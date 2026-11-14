import AidrobeKit
import PhotosUI
import SwiftUI

/// Self-contained import sheet: pick photos (album, multi-select) or take one,
/// watch each photo upload and get recognised, then confirm what was found.
/// Present it from any screen: `.sheet(isPresented:) { ImportFlowView() }`.
struct ImportFlowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ImportFlowModel?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var inputType: Endpoints.ImportInputType = .image
    @State private var openingJob: UUID?
    @State private var confirming: ConfirmTarget?

    /// Called after at least one item was added, so the caller can refresh.
    var onImported: () -> Void = {}
    /// Photos to import as soon as the sheet opens (debug harness).
    var autoImport: [UIImage] = []

    struct ConfirmTarget: Hashable {
        let jobID: UUID
        let task: Wire.ImportTaskResponse

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.jobID == rhs.jobID }
        func hash(into hasher: inout Hasher) { hasher.combine(jobID) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("照片类型", selection: $inputType) {
                        Text("单件衣物").tag(Endpoints.ImportInputType.image)
                        Text("整套穿搭").tag(Endpoints.ImportInputType.outfitImage)
                    }
                    .pickerStyle(.segmented)
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 9, matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            Label("拍一张", systemImage: "camera")
                        }
                    }
                } footer: {
                    Text(inputType == .outfitImage ? "从一张穿搭照里识别多件衣物。" : "每张照片识别一件衣物。")
                }

                if let model {
                    let pending = model.jobs.filter { $0.pendingTask != nil }
                    Section(pending.isEmpty ? "待确认" : "待确认（\(pending.count) 张照片）") {
                        ForEach(pending) { job in
                            if let task = job.pendingTask {
                                Button {
                                    openReview(job, model: model)
                                } label: {
                                    PendingImportRow(task: task, opening: openingJob == job.id)
                                }
                                .buttonStyle(.plain)
                                .disabled(openingJob != nil)
                            }
                        }
                        if model.isLoadingPending {
                            HStack(spacing: Spacing.control) {
                                ProgressView()
                                Text("正在加载导入任务…")
                            }
                        } else if let message = model.pendingError {
                            Text(message).foregroundStyle(Color.secondaryLabel)
                            Button("重试加载导入任务") { Task { await model.loadPending() } }
                        } else if pending.isEmpty {
                            Text("识别完成的照片会出现在这里").foregroundStyle(Color.secondaryLabel)
                        }
                    }
                }

                if let model {
                    let inProgress = model.jobs.filter { $0.pendingTask == nil }
                    if !inProgress.isEmpty {
                        Section("导入进度") {
                            ForEach(inProgress) { job in
                                JobRow(job: job) { Task { await model.resume(job) } }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.groupedBackground)
            .navigationTitle("添加衣物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                let input = inputType
                Task { await load(items, input: input) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in model?.importImages([image], source: .camera, input: inputType) }
                    .ignoresSafeArea()
            }
            .navigationDestination(item: $confirming) { target in
                if let model {
                    ConfirmImportView(model: model, target: target) { onImported() }
                }
            }
        }
        .task {
            if model == nil {
                model = ImportFlowModel(api: app.api)
                if !autoImport.isEmpty { model?.importImages(autoImport, source: .album) }
            }
            await model?.loadPending()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model?.loadPending() } }
        }
    }

    private func openReview(_ job: ImportFlowModel.Job, model: ImportFlowModel) {
        guard let taskID = job.taskID, openingJob == nil else { return }
        openingJob = job.id
        Task {
            defer { openingJob = nil }
            if let task = await model.review(job.id, taskID: taskID) {
                confirming = ConfirmTarget(jobID: job.id, task: task)
            }
        }
    }

    private func load(_ items: [PhotosPickerItem], input: Endpoints.ImportInputType) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        model?.importImages(images, source: .album, input: input)
    }
}

private struct PendingImportRow: View {
    let task: Wire.ImportTaskResponse
    let opening: Bool

    private var candidates: [Wire.CandidateItem] {
        let items = task.candidateItems?.isEmpty == false
            ? task.candidateItems ?? []
            : [task.candidateItem].compactMap { $0 }
        return items.filter { $0.confirmedItemId == nil }
    }

    var body: some View {
        HStack(spacing: Spacing.control) {
            GarmentImage(url: task.candidateItem.flatMap { URL(string: $0.originalImageUrl) }, forceOriginal: true, fit: true)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                let names = candidates.prefix(2).map { $0.displayName ?? $0.title }
                Text(names.isEmpty ? "识别结果" : names.joined(separator: "、"))
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text("\(candidates.count) 件待核对")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }
            Spacer()
            if opening {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct JobRow: View {
    let job: ImportFlowModel.Job
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.control) {
            Group {
                if let thumbnail = job.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(Color.tertiaryLabel)
                }
            }
            .frame(width: 48, height: 48)
            .background(Color.fill)
            .clipShape(.rect(cornerRadius: 8))

            status
            Spacer()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch job.phase {
        case .uploading:
            Label("上传中…", systemImage: "arrow.up.circle").foregroundStyle(Color.secondaryLabel)
        case .recognising:
            HStack(spacing: 8) {
                ProgressView()
                Text("识别中…").foregroundStyle(Color.secondaryLabel)
            }
        case .interrupted:
            Button("继续查看识别进度", action: onRetry)
        case .needsConfirm:
            EmptyView()
        case .confirming:
            ProgressView()
        case let .done(count):
            Label(count > 0 ? "已加入衣橱（\(count) 件）" : "已加入衣橱", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.success)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.danger)
                .font(.footnote)
        }
    }
}

/// Review what recognition found; every field stays editable and the user's
/// values win over the AI guess.
private struct ConfirmImportView: View {
    let model: ImportFlowModel
    let target: ImportFlowView.ConfirmTarget
    let onImported: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [ImportFlowModel.CandidateDraft] = []
    @State private var submitting = false
    @State private var failed = false
    @State private var showCancel = false

    private var selected: [ImportFlowModel.CandidateDraft] {
        drafts.filter { $0.include && !$0.alreadyConfirmed }
    }

    var body: some View {
        Form {
            Section {
                Button("取消确认", role: .destructive) { showCancel = true }
                    .disabled(submitting)
            }
            ForEach($drafts) { $draft in
                Section {
                    if draft.alreadyConfirmed {
                        Label("已在衣橱中", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.success)
                    } else {
                        Toggle(
                            draft.possibleDuplicates.isEmpty ? "导入这件" : "仍然导入",
                            isOn: $draft.include
                        )
                    }
                    if draft.possibleDuplicates.isEmpty {
                        GarmentImage(url: draft.imageURL, forceOriginal: true, fit: true)
                            .frame(height: 180)
                        Text(draft.imageCaption)
                            .font(.caption)
                            .foregroundStyle(Color.secondaryLabel)
                    } else {
                        ForEach(draft.possibleDuplicates, id: \.itemId) { match in
                            VStack(alignment: .leading, spacing: Spacing.tight) {
                                Label("可能已在衣橱", systemImage: "square.on.square")
                                    .font(.subheadline)
                                HStack(alignment: .top, spacing: Spacing.control) {
                                    comparison(draft.imageCaption, url: draft.imageURL)
                                    comparison(match.title, url: match.imageUrl.flatMap(URL.init(string:)))
                                }
                            }
                        }
                    }
                    Group {
                        TextField("名称", text: $draft.title)
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
                    .disabled(!draft.include || draft.alreadyConfirmed)
                }
            }
            if failed {
                Text("没能保存，请稍后再试").foregroundStyle(Color.danger)
            }
        }
            .scrollContentBackground(.hidden)
            .background(Color.groupedBackground)
            .navigationTitle(drafts.count > 1 ? "识别到 \(drafts.count) 件" : "确认衣物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后", role: .cancel) { dismiss() }
                        .disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入衣橱") {
                        submitting = true
                        Task {
                            let ok = await model.confirm(target.jobID, task: target.task, drafts: drafts)
                            submitting = false
                            if ok {
                                onImported()
                                dismiss()
                            } else {
                                failed = true
                            }
                        }
                    }
                    .disabled(submitting || selected.isEmpty || selected.contains {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
                }
            }
            .navigationBarBackButtonHidden()
            .alert("取消这次确认？", isPresented: $showCancel) {
                Button("继续核对", role: .cancel) {}
                Button("取消确认", role: .destructive) {
                    submitting = true
                    Task {
                        let ok = await model.cancel(target.jobID, task: target.task)
                        submitting = false
                        if ok { dismiss() } else { failed = true }
                    }
                }
            } message: {
                Text("这张照片里还没确认的衣物将从待确认列表移除。")
            }
            .onAppear {
                if drafts.isEmpty { drafts = model.drafts(for: target.task) }
            }
    }

    private func comparison(_ title: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            GarmentImage(url: url, forceOriginal: true, fit: true)
                .frame(height: 115)
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Minimal UIKit camera bridge (no SwiftUI camera view exists).
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
