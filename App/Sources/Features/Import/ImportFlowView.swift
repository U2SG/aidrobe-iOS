import AidrobeKit
import PhotosUI
import SwiftUI

/// Self-contained import sheet: pick photos (album, multi-select) or take one,
/// watch each photo upload and get recognised, then confirm what was found.
/// Present it from any screen: `.sheet(isPresented:) { ImportFlowView() }`.
struct ImportFlowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
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

    struct ConfirmTarget: Identifiable {
        let jobID: UUID
        let task: Wire.ImportTaskResponse
        var id: UUID { jobID }
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

                if let message = model?.pendingError {
                    Section {
                        Text(message).foregroundStyle(Color.secondaryLabel)
                        Button("重试加载导入任务") { Task { await model?.loadPending() } }
                    }
                }
                if let model, !model.jobs.isEmpty {
                    Section("导入进度") {
                        ForEach(model.jobs) { job in
                            JobRow(job: job) {
                                guard let taskID = job.taskID, openingJob == nil else { return }
                                openingJob = job.id
                                Task {
                                    if let task = await model.review(job.id, taskID: taskID) {
                                        confirming = ConfirmTarget(jobID: job.id, task: task)
                                    }
                                    openingJob = nil
                                }
                            }
                            .disabled(openingJob != nil)
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
            .sheet(item: $confirming) { target in
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

private struct JobRow: View {
    let job: ImportFlowModel.Job
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: Spacing.control) {
            Group {
                if let thumbnail = job.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else if case let .needsConfirm(task) = job.phase,
                          let candidate = task.candidateItem {
                    GarmentImage(url: URL(string: candidate.cropImageUrl ?? candidate.originalImageUrl), forceOriginal: true)
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
        case let .needsConfirm(task):
            let count = (task.candidateItems ?? []).filter { $0.confirmedItemId == nil }.count
            Button(count > 1 ? "核对 \(count) 件衣物" : "确认识别结果", action: onConfirm)
                .buttonStyle(.glassProminent)
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

    private var selected: [ImportFlowModel.CandidateDraft] {
        drafts.filter { $0.include && !$0.alreadyConfirmed }
    }

    var body: some View {
        NavigationStack {
            Form {
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
                            GarmentImage(url: draft.imageURL, forceOriginal: true)
                                .frame(height: 180)
                        } else {
                            ForEach(draft.possibleDuplicates, id: \.itemId) { match in
                                VStack(alignment: .leading, spacing: Spacing.tight) {
                                    Label("可能已在衣橱", systemImage: "square.on.square")
                                        .font(.subheadline)
                                    HStack(alignment: .top, spacing: Spacing.control) {
                                        comparison("本次识别", url: draft.imageURL)
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
                    Button(selected.isEmpty ? "跳过全部" : "加入衣橱") {
                        submitting = true
                        let didSelect = !selected.isEmpty
                        Task {
                            let ok = await model.confirm(target.jobID, task: target.task, drafts: drafts)
                            submitting = false
                            if ok {
                                if didSelect { onImported() }
                                dismiss()
                            } else {
                                failed = true
                            }
                        }
                    }
                    .disabled(submitting || drafts.isEmpty || selected.contains {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
                }
            }
        }
        .interactiveDismissDisabled(submitting)
        .onAppear { drafts = model.drafts(for: target.task) }
    }

    private func comparison(_ title: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            GarmentImage(url: url, forceOriginal: true)
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
