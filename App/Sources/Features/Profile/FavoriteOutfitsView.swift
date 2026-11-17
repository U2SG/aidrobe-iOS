import AidrobeKit
import SwiftUI

struct FavoriteOutfitsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: FavoriteOutfitsModel?

    var body: some View {
        ZStack {
            if let model { content(model) }
            else { ProgressView("正在读取收藏…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .navigationTitle("收藏穿搭")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Wire.OutfitResponse.self) { outfit in
            if let model { FavoriteOutfitDetailView(outfit: outfit, model: model) }
        }
        .task {
            if model == nil {
                model = FavoriteOutfitsModel(
                    api: app.api, wardrobe: app.wardrobe, onFavoritesChange: app.favoritesDidChange
                )
            }
            // Reset the offset after returning from a detail where a favorite may have been removed.
            await model?.load()
        }
    }

    @ViewBuilder private func content(_ model: FavoriteOutfitsModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("正在读取收藏…")
        case let .failed(message):
            ContentUnavailableView {
                Label("没能读取收藏", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("再试一次") { Task { await model.load() } }
                    .buttonStyle(.glass)
            }
        case .loaded:
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("还没有收藏穿搭", systemImage: "heart")
                } description: {
                    Text("在今日或问问的搭配里点「收藏这套」，以后都能在这里找到。")
                } actions: {
                    Button("看看今日搭配") { app.selectedTab = .today }
                        .buttonStyle(.glass)
                }
            } else {
                list(model)
            }
        }
    }

    private func list(_ model: FavoriteOutfitsModel) -> some View {
        @Bindable var model = model
        return List {
            ForEach(model.items, id: \.outfitId) { outfit in
                NavigationLink(value: outfit) {
                    let pieces = model.actions.boardItems(for: outfit, useOriginalPhotoFallback: true)
                    HStack(spacing: Spacing.row) {
                        OutfitBoard(items: pieces)
                            .frame(width: 72)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(outfit.title).font(.headline).foregroundStyle(Color.label)
                            Text(pieces.map(\.name).joined(separator: "、"))
                                .font(.subheadline)
                                .foregroundStyle(Color.secondaryLabel)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, Spacing.tight)
                    .accessibilityElement(children: .combine)
                }
                .accessibilityHint("查看这一套收藏并继续调整")
            }
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    HStack {
                        Text("加载更多收藏")
                        if model.isLoadingMore { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.isLoadingMore || model.isRefreshing)
            }
        }
        .listRowSeparatorTint(Color.separator)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
        .toast($model.notice)
    }
}

private struct FavoriteOutfitDetailView: View {
    let outfit: Wire.OutfitResponse
    let model: FavoriteOutfitsModel
    @Environment(AppModel.self) private var app
    @State private var shareDraft: OutfitShareDraft?
    @State private var favoriteReadID: UUID?

    private var isFavorite: Bool { model.actions.favoriteOutfitIDs.contains(outfit.outfitId) }
    private var pieces: [BoardItem] { model.actions.boardItems(for: outfit, useOriginalPhotoFallback: true) }

    var body: some View {
        @Bindable var actions = model.actions
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Text(isFavorite ? "收藏的这一套" : "已取消收藏").kicker()
                    Text(outfit.title)
                        .font(.display(30, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    Text(outfit.reason).foregroundStyle(Color.secondaryLabel)
                }
                OutfitBoard(items: pieces)
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: "这一套")
                    ForEach(pieces) { piece in
                        if app.wardrobe.item(piece.itemID) != nil {
                            NavigationLink {
                                ItemDetailView(itemID: piece.itemID)
                            } label: {
                                pieceRow(piece)
                            }
                            .buttonStyle(.plain)
                        } else {
                            pieceRow(piece)
                        }
                        Divider().overlay(Color.separator)
                    }
                }
                Button("从这套继续聊", systemImage: "text.bubble") {
                    var saved = outfit
                    saved.isFavorited = isFavorite
                    app.discussOutfit(saved)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(favoriteReadID != nil || actions.changingFavorites.contains(outfit.outfitId))
                .accessibilityHint("带上收藏的这套衣服，在问问里继续修改")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .background(Color.background)
        .navigationTitle("收藏穿搭")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(isFavorite ? "取消收藏" : "收藏这套", systemImage: isFavorite ? "heart.fill" : "heart") {
                    Task { await model.toggleFavorite(outfit) }
                }
                .disabled(favoriteReadID != nil || actions.changingFavorites.contains(outfit.outfitId))
                Button("分享这套", systemImage: "square.and.arrow.up") {
                    shareDraft = OutfitShareDraft(items: pieces, date: nil)
                }
            }
        }
        .toast($actions.notice)
        .sheet(item: $shareDraft) { draft in
            OutfitShareSheet(draft: draft)
        }
        .task(id: app.favoritesChange) { await refreshFavorite() }
    }

    private func refreshFavorite() async {
        let requestID = UUID()
        let change = app.favoritesChange
        let generation = AccountLocalData.generation
        favoriteReadID = requestID
        defer { if favoriteReadID == requestID { favoriteReadID = nil } }
        do {
            let current = try await app.api.send(Endpoints.outfit(outfit.outfitId))
            guard !Task.isCancelled, favoriteReadID == requestID,
                  generation == AccountLocalData.generation, change == app.favoritesChange,
                  current.outfitId == outfit.outfitId else { return }
            // This saved outfit may be outside the currently loaded favorites page.
            model.actions.syncFavorite(current)
        } catch {
            guard !Task.isCancelled, favoriteReadID == requestID,
                  generation == AccountLocalData.generation, change == app.favoritesChange else { return }
            model.actions.notice = userMessage(for: error)
        }
    }

    private func pieceRow(_ piece: BoardItem) -> some View {
        HStack(spacing: Spacing.row) {
            Text(Garment.category(piece.role))
                .font(.subheadline)
                .foregroundStyle(Color.tertiaryLabel)
                .frame(width: 52, alignment: .leading)
            Text(piece.name).foregroundStyle(Color.label)
            Spacer(minLength: Spacing.tight)
            if app.wardrobe.item(piece.itemID) != nil {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Color.tertiaryLabel)
            }
        }
        .frame(minHeight: 48)
        .contentShape(.rect)
    }
}

@MainActor
@Observable
private final class FavoriteOutfitsModel {
    enum Phase {
        case loading, loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [Wire.OutfitResponse] = []
    private(set) var hasMore = false
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    var notice: String?
    let actions: TodayModel

    private let api: APIClient
    private let wardrobe: WardrobeStore
    private let accountGeneration = AccountLocalData.generation
    private var loadID = UUID()
    private var offset = 0

    init(api: APIClient, wardrobe: WardrobeStore, onFavoritesChange: @escaping () -> Void) {
        self.api = api
        self.wardrobe = wardrobe
        actions = TodayModel(api: api, wardrobe: wardrobe, onFavoritesChange: onFavoritesChange)
    }

    func load() async {
        guard accountGeneration == AccountLocalData.generation else { return }
        let requestID = UUID()
        loadID = requestID
        isRefreshing = true
        if items.isEmpty { phase = .loading }
        defer { if loadID == requestID { isRefreshing = false } }
        do {
            async let firstPage = api.send(Endpoints.favoriteOutfits())
            async let wardrobeLoad: Void = wardrobe.items.isEmpty ? wardrobe.load() : ()
            let (page, _) = try await (firstPage, wardrobeLoad)
            guard isCurrent(requestID) else { return }
            items = page.items
            offset = page.offset + page.items.count
            hasMore = page.hasMore
            for outfit in items { actions.syncOutfit(outfit) }
            phase = .loaded
        } catch {
            guard isCurrent(requestID) else { return }
            if items.isEmpty { phase = .failed(userMessage(for: error)) }
            else { notice = userMessage(for: error) }
        }
    }

    func loadMore() async {
        guard hasMore, !isRefreshing, !isLoadingMore else { return }
        let requestID = loadID
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.send(Endpoints.favoriteOutfits(offset: offset))
            guard isCurrent(requestID) else { return }
            let known = Set(items.map(\.outfitId))
            items += page.items.filter { !known.contains($0.outfitId) }
            offset = page.offset + page.items.count
            hasMore = page.hasMore
            for outfit in page.items { actions.syncOutfit(outfit) }
        } catch {
            if isCurrent(requestID) { notice = userMessage(for: error) }
        }
    }

    func toggleFavorite(_ outfit: Wire.OutfitResponse) async {
        guard await actions.toggleFavorite(outfit) else { return }
        // Removing a row shifts offset pagination; rebuild from the first page.
        await load()
    }

    private func isCurrent(_ requestID: UUID) -> Bool {
        loadID == requestID && accountGeneration == AccountLocalData.generation && !Task.isCancelled
    }
}
