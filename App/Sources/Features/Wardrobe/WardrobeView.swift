import AidrobeKit
import SwiftUI

/// The wardrobe as a quiet catalogue: filter by kind, search by name, open a
/// garment to see how it has been worn.
struct WardrobeView: View {
    @Environment(AppModel.self) private var app
    @State private var category: String?
    @State private var query = ""
    @State private var notice: String?
    @State private var isImporting = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.control), count: 2)

    private var store: WardrobeStore { app.wardrobe }

    private var visible: [Wire.WardrobeItemResponse] {
        store.items
            .filter { item in
                (category == nil || item.category == category)
                    && (query.isEmpty || item.displayName.localizedCaseInsensitiveContains(query))
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
                        Text("放进一件上装、一件下装和一双鞋，就能搭出第一套。")
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
        .toast($notice)
        .task { await store.load() }
        .task(id: store.hasPendingProductImages) { await store.refreshPendingProductImages() }
    }

    private var catalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.row) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                    .padding(.horizontal, Spacing.screen)
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
                    Text("没有找到「\(query)」")
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
                fit: true
            )
                .aspectRatio(0.8, contentMode: .fit)
                .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.tile))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.separator))
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
        if item.cutoutStatus == "queued" { return "正在生成商品图…" }
        let wears = item.wearCount ?? 0
        return wears == 0 ? Garment.color(item.colorMain) : "\(Garment.color(item.colorMain)) · 穿过 \(wears) 次"
    }
}
