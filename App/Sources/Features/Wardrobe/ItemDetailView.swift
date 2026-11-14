import AidrobeKit
import SwiftUI

/// One garment: its picture, how it has been worn, and whether it can be
/// picked for an outfit right now.
struct ItemDetailView: View {
    let itemID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showsOriginal = false
    @State private var isEditing = false
    @State private var confirmsDelete = false
    @State private var notice: String?

    private var store: WardrobeStore { app.wardrobe }

    var body: some View {
        Group {
            if let item = store.item(itemID) {
                page(item)
            } else {
                Color.clear
            }
        }
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .toast($notice)
    }

    private func page(_ item: Wire.WardrobeItemResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                GarmentImage(
                    url: showsOriginal ? WardrobeStore.originalURL(item) : WardrobeStore.imageURL(item),
                    forceOriginal: true,
                    fit: true,
                    matchProductBackground: !showsOriginal && item.cutoutStatus == "ready"
                )
                    .aspectRatio(1, contentMode: .fit)
                    .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.card))
                    .overlay(alignment: .bottomTrailing) {
                        if let original = item.originalImageUrl, let cover = item.coverImageUrl, original != cover {
                            Button(showsOriginal ? (item.cutoutStatus == "ready" ? "看商品图" : "看封面") : "看原图") {
                                showsOriginal.toggle()
                            }
                                .font(.footnote)
                                .buttonStyle(.glass)
                                .padding(Spacing.control)
                        }
                    }
                if item.cutoutStatus == "queued" {
                    Label("正在生成商品图…", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                } else if item.cutoutStatus == "rejected" {
                    Text("商品图未通过核对，已保留参考图")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                } else if item.cutoutStatus == "failed" {
                    Text("商品图生成失败，已保留参考图")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                } else if item.cutoutStatus == "skipped" {
                    Text("暂无商品图")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.displayName)
                        .font(.display(28, weight: .black, relativeTo: .title))
                        .foregroundStyle(Color.label)
                    Text("\(Garment.category(item.category)) · \(Garment.color(item.colorMain))")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                VStack(spacing: 0) {
                    Divider().overlay(Color.separator)
                    FactRow(title: "穿过") {
                        Text((item.wearCount ?? 0) == 0 ? "还没穿过" : "\(item.wearCount ?? 0) 次")
                    }
                    if let last = Garment.day(item.lastWorn) {
                        FactRow(title: "上次穿") { Text(last) }
                    }
                    if let seasons = Garment.seasons(item.seasonTags) {
                        FactRow(title: "季节") { Text(seasons) }
                    }
                    if let material = item.material, !material.isEmpty {
                        FactRow(title: "材质") { Text(Garment.material(material)) }
                    }
                    if let formality = Garment.formality(item.formalityScore) {
                        FactRow(title: "场合") { Text(formality) }
                    }
                    FactRow(title: "现在") {
                        Menu {
                            Picker("现在", selection: statusBinding(item)) {
                                ForEach(Wire.WardrobeItemStatus.allCases, id: \.self) { status in
                                    Text(Garment.status(status)).tag(status)
                                }
                            }
                        } label: {
                            menuLabel(Garment.status(item.status))
                        }
                    }
                    FactRow(title: "合身") {
                        Menu {
                            Picker("合身", selection: fitBinding(item)) {
                                ForEach(Wire.FitStatus.allCases.filter { $0 != .unknown }, id: \.self) { fit in
                                    Text(Garment.fit(fit.rawValue)).tag(fit)
                                }
                            }
                        } label: {
                            menuLabel(Garment.fit(item.fitStatus))
                        }
                    }
                }
                Button {
                    perform("记下了") { try await store.markWorn(item.itemId) }
                } label: {
                    Text("今天穿了这件").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(Spacing.screen)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("更多", systemImage: "ellipsis") {
                    Button("修改", systemImage: "pencil") { isEditing = true }
                    Button("从衣橱移除", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                }
            }
        }
        .sheet(isPresented: $isEditing) { ItemEditSheet(item: item) }
        .confirmationDialog("移除「\(item.displayName)」？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                Task {
                    do {
                        try await store.delete(item.itemId)
                        dismiss()
                    } catch {
                        notice = userMessage(for: error)
                    }
                }
            }
        } message: {
            Text("它的穿着记录也会一起删除，之后不会再出现在搭配里。")
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").font(.caption)
        }
        .foregroundStyle(Color.label)
        .frame(minHeight: 44)
    }

    private func statusBinding(_ item: Wire.WardrobeItemResponse) -> Binding<Wire.WardrobeItemStatus> {
        Binding(get: { item.status }, set: { status in
            perform(status == .wearable ? "放回衣橱了" : "之后的搭配会先跳过它") {
                try await store.update(item.itemId, .init(status: status))
            }
        })
    }

    private func fitBinding(_ item: Wire.WardrobeItemResponse) -> Binding<Wire.FitStatus> {
        Binding(get: { Wire.FitStatus(rawValue: item.fitStatus) ?? .unknown }, set: { fit in
            perform("记下了") { try await store.updateFit(item.itemId, fit) }
        })
    }

    private func perform(_ success: String, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                notice = success
            } catch {
                notice = userMessage(for: error)
            }
        }
    }
}

private struct ItemEditSheet: View {
    let item: Wire.WardrobeItemResponse
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var category: String
    @State private var color: String
    @State private var material: String
    @State private var seasons: Set<String>
    @State private var formality: Int
    @State private var failure: String?

    init(item: Wire.WardrobeItemResponse) {
        self.item = item
        _name = State(initialValue: item.displayName)
        _category = State(initialValue: item.category)
        _color = State(initialValue: item.colorMain.lowercased())
        _material = State(initialValue: item.material?.lowercased() ?? "")
        _seasons = State(initialValue: Set(item.seasonTags ?? []))
        // Snap a recognised score onto the nearest option; 0 = not recorded.
        _formality = State(initialValue: Garment.formalityOptions.last { $0.score - 10 <= (item.formalityScore ?? 0) }?.score ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("名称", text: $name)
                }
                Section {
                    Picker("分类", selection: $category) {
                        ForEach(Garment.categories, id: \.self) { Text(Garment.category($0)).tag($0) }
                    }
                    Picker("主色", selection: $color) {
                        if Garment.swatch(color) == nil { Text(color).tag(color) }
                        ForEach(Garment.colors, id: \.key) { Text($0.label).tag($0.key) }
                    }
                }
                Section {
                    Picker("材质", selection: $material) {
                        if !Garment.materials.contains(where: { $0.key == material }) {
                            Text(material.isEmpty ? "没记录" : material).tag(material)
                        }
                        ForEach(Garment.materials, id: \.key) { Text($0.label).tag($0.key) }
                    }
                    Picker("场合", selection: $formality) {
                        if formality == 0 { Text("没记录").tag(0) }
                        ForEach(Garment.formalityOptions, id: \.score) { Text($0.label).tag($0.score) }
                    }
                    VStack(alignment: .leading, spacing: Spacing.control) {
                        Text("季节")
                        FlowLayout {
                            ForEach(Garment.seasonOptions, id: \.key) { option in
                                Chip(title: option.label, isSelected: seasons.contains(option.key)) {
                                    toggleSeason(option.key)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(Color.danger)
                    } else {
                        Text("搭配会按季节和场合挑选，你改过的内容不会再被识别结果覆盖。")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.groupedBackground)
            .navigationTitle("修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do {
                                let title = name.trimmingCharacters(in: .whitespaces)
                                try await app.wardrobe.update(item.itemId, .init(
                                    title: title,
                                    category: category,
                                    colorMain: color,
                                    material: material.isEmpty ? nil : material,
                                    seasonTags: Garment.seasonOptions.map(\.key).filter(seasons.contains)
                                        .compactMap(Wire.UpdateWardrobeItemRequest.SeasonTagsPayloadPayload.init(rawValue:)),
                                    formalityScore: formality == 0 ? nil : formality
                                ))
                                dismiss()
                            } catch {
                                failure = userMessage(for: error)
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    /// "All year" and the individual seasons exclude each other.
    private func toggleSeason(_ key: String) {
        if seasons.contains(key) {
            seasons.remove(key)
        } else if key == "all_season" {
            seasons = [key]
        } else {
            seasons.remove("all_season")
            seasons.insert(key)
        }
    }
}
