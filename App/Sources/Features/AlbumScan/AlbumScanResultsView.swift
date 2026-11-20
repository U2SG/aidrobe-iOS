import AidrobeKit
import SwiftUI

/// Garments found across the scanned photos, one row per garment: new pieces,
/// pieces that look like something already in the wardrobe, and ones to check.
struct AlbumScanResultsView: View {
    @Bindable var model: AlbumScanModel
    let batch: Wire.ImportBatchResponse
    let onImported: () -> Void
    @State private var sources: Wire.ImportBatchGroup?

    private var saving: Bool {
        if case .saving = model.phase { true } else { false }
    }

    private func groups(_ kind: Wire.ImportBatchGroup.KindPayload) -> [Wire.ImportBatchGroup] {
        batch.groups.filter { $0.kind == kind && $0.status != .confirmed }
    }

    var body: some View {
        List {
            Section {
                Text(model.ledger.lastTally.summary)
                if batch.comparisonLimited == true {
                    Label("今天的比对额度用完了，部分同一件衣服可能分开显示", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if batch.failed > 0 {
                    Text("\(batch.failed) 张照片没能识别")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
            }
            if batch.groups.isEmpty {
                Text("照片里没有找到可以加入的衣物").foregroundStyle(Color.secondaryLabel)
            }
            section("新衣物", kind: .new)
            section("可能已在衣橱", kind: .existing)
            section("不确定", kind: .uncertain, footer: "最像的那件不一定是同一件，看清楚再选。")
            let done = batch.groups.filter { $0.status == .confirmed }
            if !done.isEmpty {
                Section("已加入") {
                    ForEach(done, id: \.groupId) { group in
                        Label(group.existingItem?.title ?? group.title, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.success)
                    }
                }
            }
            SkipSummarySection(model: model)
        }
        .scrollContentBackground(.hidden)
        .disabled(saving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("确认") {
                        Task { if await model.confirm(batch) { onImported() } }
                    }
                    .disabled(invalid)
                }
            }
        }
        .sheet(item: $sources) { group in
            SourcePhotosView(group: group)
        }
    }

    private var invalid: Bool {
        batch.groups.contains { group in
            guard group.status != .confirmed, let draft = model.drafts[group.groupId] else { return false }
            return draft.choice == .create && draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private func section(_ title: String, kind: Wire.ImportBatchGroup.KindPayload, footer: String? = nil) -> some View {
        let groups = groups(kind)
        if !groups.isEmpty {
            Section {
                ForEach(groups, id: \.groupId) { group in
                    if let draft = Binding($model.drafts[group.groupId]) {
                        GroupRow(group: group, draft: draft) { sources = group }
                    }
                }
            } header: {
                Text("\(title)（\(groups.count)）")
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }
}

extension Wire.ImportBatchGroup: @retroactive Identifiable {
    public var id: String { groupId }
}

private struct GroupRow: View {
    let group: Wire.ImportBatchGroup
    @Binding var draft: AlbumScanModel.Draft
    let showSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            header
            if group.members.count > 1 {
                Button(action: showSources) {
                    HStack(spacing: Spacing.tight) {
                        ForEach(group.members.prefix(6), id: \.tempItemId) { member in
                            GarmentImage(url: (member.cropUrl ?? member.photoUrl).flatMap(URL.init(string:)), forceOriginal: true)
                                .frame(width: 44, height: 44)
                        }
                        if group.members.count > 6 {
                            Text("+\(group.members.count - 6)").font(.footnote).foregroundStyle(Color.secondaryLabel)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("看来源照片")
            }
            decision
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.control) {
            Button(action: showSources) {
                // No crop (too small to cut out): show the source photo rather than an empty tile.
                GarmentImage(
                    url: (group.bestCropUrl ?? group.members.lazy.compactMap(\.photoUrl).first)
                        .flatMap(URL.init(string:)),
                    forceOriginal: true, fit: true
                )
                    .frame(width: 72, height: 72)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("看来源照片")
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.choice == .create ? draft.title : group.title)
                    .font(.headline)
                    .foregroundStyle(Color.label)
                Text("\(Garment.category(group.category)) · \(Garment.color(group.colorMain))")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                Text(group.members.count > 1 ? "出现在 \(group.members.count) 张照片里" : "出现在 1 张照片里")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryLabel)
            }
            if let existing = group.existingItem {
                Spacer()
                GarmentImage(url: existing.imageUrl.flatMap(URL.init(string:)), fit: true)
                    .frame(width: 72, height: 72)
            }
        }
    }

    @ViewBuilder
    private var decision: some View {
        switch group.kind {
        case .new:
            Toggle("加入衣橱", isOn: choiceBinding(on: .create))
            if draft.choice == .create { editor }
            backfill
        case .existing:
            Text("这是你的〈\(group.existingItem?.title ?? group.title)〉吗？")
                .foregroundStyle(Color.label)
            Toggle("是，记到这件上", isOn: choiceBinding(on: .link))
            backfill
        case .uncertain:
            if let existing = group.existingItem {
                Text("和你的〈\(existing.title)〉是同一件吗？")
                    .foregroundStyle(Color.label)
                Picker("怎么处理", selection: $draft.choice) {
                    Text("不加入").tag(AlbumScan.Choice.skip)
                    Text("是同一件").tag(AlbumScan.Choice.link)
                    Text("是新的一件").tag(AlbumScan.Choice.create)
                }
                .pickerStyle(.segmented)
                backfill
            } else {
                Toggle("要加入衣橱吗？", isOn: choiceBinding(on: .create))
            }
            if draft.choice == .create { editor }
            if group.existingItem == nil { backfill }
        }
    }

    @ViewBuilder
    private var backfill: some View {
        let dates = group.wearDates ?? []
        // A photo shows the garment was worn that day, for a new garment as much as a known one.
        if draft.choice == .link || draft.choice == .create, !dates.isEmpty {
            Toggle(AlbumScan.backfillLabel(dates), isOn: $draft.backfill)
                .font(.subheadline)
        }
    }

    private var editor: some View {
        Group {
            TextField("名称", text: $draft.title)
            Picker("类别", selection: $draft.category) {
                if !Garment.categories.contains(draft.category) {
                    Text(Garment.category(draft.category)).tag(draft.category)
                }
                ForEach(Garment.categories, id: \.self) { Text(Garment.category($0)).tag($0) }
            }
            Picker("主色", selection: $draft.color) {
                if Garment.swatch(draft.color) == nil { Text(Garment.color(draft.color)).tag(draft.color) }
                ForEach(Garment.colors, id: \.key) { Text($0.label).tag($0.key) }
            }
        }
    }

    private func choiceBinding(on choice: AlbumScan.Choice) -> Binding<Bool> {
        Binding(get: { draft.choice == choice }, set: { draft.choice = $0 ? choice : .skip })
    }
}

/// The photos a garment was found in, so the user can tell whether it is theirs.
private struct SourcePhotosView: View {
    let group: Wire.ImportBatchGroup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.row) {
                    ForEach(group.members, id: \.tempItemId) { member in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            GarmentImage(
                                url: (member.photoUrl ?? member.cropUrl).flatMap(URL.init(string:)),
                                forceOriginal: true, fit: true, photoAspectRatio: 3 / 4
                            )
                            if let day = member.takenAt {
                                Text(AlbumScan.shortDay(day)).kicker()
                            }
                        }
                    }
                }
                .padding(Spacing.screen)
            }
            .background(Color.groupedBackground)
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
