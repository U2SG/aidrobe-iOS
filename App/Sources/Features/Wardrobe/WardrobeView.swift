import AidrobeKit
import SwiftUI

/// The wardrobe as a quiet catalogue: filter by kind, search by name, open a
/// garment to see how it has been worn.
struct WardrobeView: View {
    @Environment(AppModel.self) private var app
    @State private var category: String?
    @State private var status: Wire.WardrobeItemStatus?
    @State private var season: String?
    @State private var color: String?
    @State private var showsFilters = false
    @State private var query = ""
    @State private var notice: String?
    @State private var isImporting = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.control), count: 2)

    private var store: WardrobeStore { app.wardrobe }

    private var activeFilters: Int { [status?.rawValue, season, color].compactMap { $0 }.count }

    private var colors: [String] {
        Set(store.items.map { $0.colorMain.lowercased() }).filter { !$0.isEmpty }.sorted()
    }

    private var visible: [Wire.WardrobeItemResponse] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.items
            .filter { item in
                (category == nil || item.category == category)
                    && (status == nil || item.status == status)
                    && (season == nil || (item.seasonTags ?? []).contains { $0 == season || $0 == "all_season" })
                    && (color == nil || item.colorMain.lowercased() == color)
                    && (search.isEmpty || item.displayName.localizedCaseInsensitiveContains(search)
                        || Garment.color(item.colorMain).localizedCaseInsensitiveContains(search))
            }
            // Stable sort: grouped by kind, newest first within a kind (the server's order).
            .sorted { rank($0.category) < rank($1.category) }
    }

    private func rank(_ category: String) -> Int {
        Garment.categories.firstIndex(of: category) ?? Garment.categories.count
    }

    /// Kinds the user actually owns, in wardrobe order, with their counts.
    private var categories: [(key: String, count: Int)] {
        Garment.categories.compactMap { key in
            let count = store.items.count { $0.category == key }
            return count > 0 ? (key, count) : nil
        }
    }

    var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                ProgressView()
            case let .failed(message):
                ContentUnavailableView {
                    Label("没能打开衣橱", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("再试一次") { Task { await store.load() } }
                        .buttonStyle(.glass)
                }
            case .loaded:
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("衣橱还是空的", systemImage: "hanger")
                    } description: {
                        Text("放进一件上装、一件下装和一双鞋，就能搭出第一套。不用一次录完，先放这一季能穿的 \(Season.starterCount) 件左右就够用了。")
                    } actions: {
                        Button("添加衣物") { isImporting = true }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    catalogue
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .navigationTitle("衣橱")
        .navigationDestination(for: String.self) { ItemDetailView(itemID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加衣物", systemImage: "plus") { isImporting = true }
            }
        }
        .sheet(isPresented: $isImporting) {
            ImportFlowView { Task { await store.load() } }
        }
        .sheet(isPresented: $showsFilters) { filters }
        .toast($notice)
        .task { await store.load() }
        .task(id: store.hasPendingProductImages) { await store.refreshPendingProductImages() }
    }

    private var catalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.row) {
                HStack {
                    Text(activeFilters > 0 ? "找到 \(visible.count) 件" : summary)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                    Spacer()
                    Button(activeFilters == 0 ? "筛选" : "筛选 · \(activeFilters)", systemImage: "line.3.horizontal.decrease") {
                        showsFilters = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                }
                .padding(.horizontal, Spacing.screen)
                if activeFilters == 0, store.inSeasonCount < Season.starterCount {
                    Text("\(Garment.seasonName(Season.current()))能穿的有 \(store.inSeasonCount) 件。不用一次录完，先补到 \(Season.starterCount) 件左右就够天天搭了。")
                        .font(.footnote)
                        .foregroundStyle(Color.tertiaryLabel)
                        .padding(.horizontal, Spacing.screen)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.tight) {
                        Chip(title: "全部", isSelected: category == nil) { category = nil }
                        ForEach(categories, id: \.key) { entry in
                            Chip(title: "\(Garment.category(entry.key)) \(entry.count)", isSelected: category == entry.key) {
                                category = category == entry.key ? nil : entry.key
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, Spacing.screen, for: .scrollContent)
                .scrollIndicators(.hidden)
                if visible.isEmpty {
                    Text("没有符合条件的衣物")
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                        .padding(.horizontal, Spacing.screen)
                        .padding(.top, Spacing.row)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.section - 8) {
                        ForEach(visible, id: \.itemId) { item in
                            NavigationLink(value: item.itemId) {
                                WardrobeTile(item: item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(.horizontal, Spacing.screen)
                    .padding(.top, 4)
                }
            }
            .padding(.bottom, Spacing.section)
        }
        .searchable(text: $query, prompt: "找一件衣服")
        .refreshable { await store.load() }
        .animation(.snappy, value: category)
    }

    private var filters: some View {
        NavigationStack {
            Form {
                Picker("状态", selection: $status) {
                    Text("全部").tag(nil as Wire.WardrobeItemStatus?)
                    ForEach(Wire.WardrobeItemStatus.allCases, id: \.self) { value in
                        Text(Garment.status(value)).tag(Optional(value))
                    }
                }
                Picker("季节", selection: $season) {
                    Text("全部").tag(nil as String?)
                    ForEach(Garment.seasonOptions, id: \.key) { option in
                        Text(option.label).tag(Optional(option.key))
                    }
                }
                Picker("颜色", selection: $color) {
                    Text("全部").tag(nil as String?)
                    ForEach(colors, id: \.self) { value in
                        Text(Garment.color(value)).tag(Optional(value))
                    }
                }
                Button("清除筛选") {
                    status = nil
                    season = nil
                    color = nil
                }
                .disabled(activeFilters == 0)
            }
            .navigationTitle("筛选衣橱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsFilters = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var summary: String {
        let resting = store.items.count { $0.status != .wearable }
        return resting == 0 ? "\(store.items.count) 件，都可以穿" : "\(store.items.count) 件，其中 \(resting) 件暂时穿不了"
    }

    @ViewBuilder private func menu(for item: Wire.WardrobeItemResponse) -> some View {
        Button("今天穿了", systemImage: "checkmark") {
            perform("记下了") { try await store.markWorn(item.itemId) }
        }
        if item.status == .wearable {
            Button("拿去洗了", systemImage: "washer") {
                perform("洗好前不会再搭到它") { try await store.update(item.itemId, .init(status: .dirty)) }
            }
        } else {
            Button("可以穿了", systemImage: "arrow.uturn.backward") {
                perform("放回衣橱了") { try await store.update(item.itemId, .init(status: .wearable)) }
            }
        }
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

private struct WardrobeTile: View {
    let item: Wire.WardrobeItemResponse

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            GarmentImage(
                url: WardrobeStore.imageURL(item),
                forceOriginal: true,
                fit: true,
                matchProductBackground: item.cutoutStatus == "ready"
            )
                .aspectRatio(0.8, contentMode: .fit)
                .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.tile))
                .opacity(item.status == .wearable ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
        .contentShape(.rect)
    }

    private var detail: String {
        if item.status != .wearable { return Garment.status(item.status) }
        if item.cutoutStatus == "queued" { return "正在生成单品图…" }
        let wears = item.wearCount ?? 0
        return wears == 0 ? Garment.color(item.colorMain) : "\(Garment.color(item.colorMain)) · 穿过 \(wears) 次"
    }
}
