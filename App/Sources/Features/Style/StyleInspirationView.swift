import AidrobeKit
import PhotosUI
import SwiftUI

struct StyleInspirationView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [Wire.InspirationResponse] = []
    @State private var tags: Set<String> = []
    @State private var savedTags: Set<String>?
    @State private var isSavingTags = false
    @State private var isLoading = false
    @State private var nextOffset: Int?
    @State private var loadError: String?
    @State private var tagsError: String?
    @State private var notice: String?
    @State private var showsAdd = false
    @State private var removeID: String?

    private static let choices = [
        ("minimal", "简洁"), ("soft", "柔和"), ("formal", "正式"),
        ("casual", "休闲"), ("street", "街头"), ("sporty", "运动"),
    ]
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: Spacing.control)]
    private var canSaveTags: Bool {
        savedTags != nil && tags != savedTags && (1...20).contains(tags.count) && !isSavingTags
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                Text("收藏想借鉴的搭配、参考图和杂志。")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                preferences
                VStack(alignment: .leading, spacing: Spacing.row) {
                    SectionHeading(title: "参考资料")
                    if items.isEmpty && !isLoading && loadError == nil {
                        Text("还没有参考图或杂志。")
                            .foregroundStyle(Color.secondaryLabel)
                        Button("添加参考", systemImage: "plus") { showsAdd = true }
                            .buttonStyle(.glass)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.row) {
                        ForEach(items, id: \.id) { item in
                            sourceTile(item)
                        }
                    }
                    if isLoading { ProgressView("正在读取参考资料…") }
                    if let loadError {
                        Text(loadError).font(.footnote).foregroundStyle(Color.danger)
                        Button("重试") { Task { await load() } }
                    } else if let nextOffset {
                        Button("加载更多") { Task { await load(offset: nextOffset) } }
                            .disabled(isLoading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .background(Color.background)
        .navigationTitle("风格灵感")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加参考", systemImage: "plus") { showsAdd = true }
            }
        }
        .sheet(isPresented: $showsAdd) {
            AddStyleInspirationSheet { Task { await load() } }
        }
        .confirmationDialog("移除这条参考？", isPresented: Binding(
            get: { removeID != nil }, set: { if !$0 { removeID = nil } }
        )) {
            Button("移除", role: .destructive) {
                if let removeID { Task { await remove(removeID) } }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toast($notice)
    }

    @ViewBuilder private var preferences: some View {
        if savedTags != nil {
            VStack(alignment: .leading, spacing: Spacing.control) {
                SectionHeading(title: "我喜欢的风格")
                FlowLayout {
                    ForEach(Self.choices, id: \.0) { key, label in
                        Chip(title: label, isSelected: tags.contains(key)) {
                            tags.formSymmetricDifference([key])
                        }
                    }
                }
                let otherTags = tags.subtracting(Self.choices.map(\.0)).sorted()
                if !otherTags.isEmpty {
                    Text(otherTags.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if tags != savedTags {
                    if tags.isEmpty {
                        Text("请至少选一种风格。").font(.footnote).foregroundStyle(Color.secondaryLabel)
                    }
                    Button(isSavingTags ? "正在保存…" : "保存风格") { Task { await saveTags() } }
                        .buttonStyle(.glass)
                        .disabled(!canSaveTags)
                }
            }
            .disabled(isSavingTags)
        }
        if let tagsError {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(tagsError).font(.footnote).foregroundStyle(Color.danger)
                Button("重新读取风格偏好") { Task { await loadTags() } }
            }
        }
    }

    private func sourceTile(_ item: Wire.InspirationResponse) -> some View {
        let pdf = item.sourceType == "pdf_magazine"
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            RoundedRectangle(cornerRadius: Radius.tile)
                .fill(Color.elevatedBackground)
                .frame(height: 130)
                .overlay {
                    Image(systemName: pdf ? "book.closed" : "photo")
                        .foregroundStyle(Color.secondaryLabel)
                }
                .overlay {
                    if let raw = item.imageUrl, let url = publicURL(raw) {
                        GeometryReader { space in
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: { Color.clear }
                            .frame(width: space.size.width, height: space.size.height)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: Radius.tile))
            Text(pdf ? "PDF 杂志" : "穿搭参考").font(.subheadline.weight(.medium))
            Text(Self.status(item.learnStatus))
                .font(.caption)
                .foregroundStyle(Color.secondaryLabel)
            if let raw = item.sourceUrl, let url = publicURL(raw) {
                Link("打开来源", destination: url).font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("移除参考", systemImage: "trash", role: .destructive) { removeID = item.id }
        }
    }

    private static func status(_ raw: String?) -> String {
        switch raw {
        case "queued": "等待处理"
        case "processing": "处理中"
        case "learned": "已处理"
        case "failed": "处理失败"
        default: "已添加"
        }
    }

    private func load(offset: Int = 0) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        if offset == 0, tags == savedTags || savedTags == nil, !isSavingTags {
            await loadTags()
        }
        do {
            let page = try await app.api.send(Endpoints.inspirations(offset: offset))
            if offset == 0 { items = page.items }
            else {
                let known = Set(items.map(\.id))
                items += page.items.filter { !known.contains($0.id) }
            }
            nextOffset = page.items.count < 30 ? nil : offset + page.items.count
        } catch {
            loadError = userMessage(for: error)
        }
    }

    private func loadTags() async {
        tagsError = nil
        do {
            let result = try await app.api.send(Endpoints.styleTags())
            savedTags = Set(result.tags)
            tags = Set(result.tags)
        } catch {
            tagsError = "没能读取风格偏好。"
        }
    }

    private func saveTags() async {
        guard canSaveTags else { return }
        isSavingTags = true
        defer { isSavingTags = false }
        do {
            _ = try await app.api.send(Endpoints.updateStyleTags(tags.sorted()))
            savedTags = tags
            notice = "风格已保存"
        } catch { notice = userMessage(for: error) }
    }

    private func remove(_ id: String) async {
        do {
            _ = try await app.api.send(Endpoints.removeInspiration(id))
            items.removeAll { $0.id == id }
            if let offset = nextOffset { nextOffset = max(0, offset - 1) }
        } catch { notice = userMessage(for: error) }
    }
}

private struct AddStyleInspirationSheet: View {
    private enum Source: String, CaseIterable {
        case photo = "相册", link = "参考链接", pdf = "PDF 杂志"
    }

    let onAdded: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .photo
    @State private var picked: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var urlText = ""
    @State private var pending = false
    @State private var loadingPhoto = false
    @State private var uploadedImageURL: String?
    @State private var errorMessage: String?

    var body: some View {
        let photoLabel = image == nil ? "从相册选择参考图" : "换一张参考图"
        NavigationStack {
            Form {
                Picker("来源", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if source == .photo {
                    Section {
                        PhotosPicker(selection: $picked, matching: .images) {
                            Label(photoLabel, systemImage: "photo")
                        }
                        if loadingPhoto {
                            ProgressView("正在读取照片…")
                        } else if let image {
                            Image(uiImage: image)
                                .resizable().scaledToFit().frame(maxHeight: 240)
                                .accessibilityLabel("已选参考图")
                        }
                    } footer: {
                        Text("提交后，参考图会发送给服务处理。")
                    }
                } else {
                    Section {
                        TextField(source == .pdf ? "公开 PDF 链接" : "穿搭参考链接", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text(source == .pdf ? "请填写可直接打开 PDF 的链接。" : "添加一条你喜欢的穿搭来源。")
                    }
                }
                if pending { ProgressView("正在添加参考…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(Color.danger) }
            }
            .navigationTitle("添加风格参考")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(pending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { Task { await add() } }
                        .disabled(pending || (source == .photo ? loadingPhoto || image == nil : publicURL(urlText) == nil))
                }
            }
            .disabled(pending)
            .interactiveDismissDisabled(pending)
            .task(id: picked) { await readPhoto() }
            .onChange(of: source) { errorMessage = nil }
        }
    }

    private func readPhoto() async {
        guard let picked else { return }
        loadingPhoto = true
        image = nil
        uploadedImageURL = nil
        errorMessage = nil
        let data = try? await picked.loadTransferable(type: Data.self)
        guard !Task.isCancelled else { return }
        image = data.flatMap { UIImage(data: $0) }
        if image == nil { errorMessage = "读不到这张照片，请重新选择。" }
        loadingPhoto = false
    }

    private func add() async {
        guard !pending else { return }
        pending = true
        errorMessage = nil
        defer { pending = false }
        do {
            switch source {
            case .photo:
                if uploadedImageURL == nil {
                    guard let image, let data = ImageCompressor.jpegData(from: image) else {
                        errorMessage = "没能准备照片，请重新选择。"
                        return
                    }
                    let upload = try await PresignedUploader(api: app.api).upload(
                        data, fileName: "reference-\(UUID().uuidString).jpg", contentType: "image/jpeg"
                    )
                    uploadedImageURL = upload.fileURL.absoluteString
                }
                _ = try await app.api.send(Endpoints.addInspiration(imageURL: uploadedImageURL))
            case .link, .pdf:
                guard let url = publicURL(urlText)?.absoluteString, url.count <= 1024 else {
                    errorMessage = "请输入有效的链接。"
                    return
                }
                if source == .pdf {
                    _ = try await app.api.send(Endpoints.addStyleMagazine(url: url))
                } else {
                    _ = try await app.api.send(Endpoints.addInspiration(sourceURL: url))
                }
            }
            onAdded()
            dismiss()
        } catch {
            errorMessage = (error as? APIError)?.status == 503 && source == .pdf
                ? "当前服务暂未开启 PDF 杂志处理。"
                : userMessage(for: error)
        }
    }
}

private func publicURL(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
}
