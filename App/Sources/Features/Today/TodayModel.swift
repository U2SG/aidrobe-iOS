import AidrobeKit
import Foundation

/// One garment as the board shows it. `slotID` is the item the recommendation
/// chose; `itemID` differs once the user swaps the piece for another.
struct BoardItem: Identifiable, Equatable {
    let slotID: String
    let itemID: String
    let role: String
    let name: String
    let imageURL: URL?

    var id: String { slotID }
    var isSwapped: Bool { slotID != itemID }
}

/// A situation the user can tell Today about; the backend maps each to fixed
/// generation constraints (`context_override.py`).
struct ContextChip: Identifiable, Equatable {
    let id: String
    let title: String

    static let all = [
        ContextChip(id: "meeting", title: "今天有会"),
        ContextChip(id: "comfy", title: "想舒服一点"),
        ContextChip(id: "walk", title: "要走很多路"),
        ContextChip(id: "lowKey", title: "想低调一点"),
        ContextChip(id: "coldOffice", title: "办公室有点冷"),
        ContextChip(id: "stayIn", title: "不怎么出门"),
        ContextChip(id: "noSkirt", title: "不想穿裙子"),
    ]
}

@MainActor
@Observable
final class TodayModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var today: Wire.TodayRecommendationResponse?
    private(set) var wornOutfitIDs: Set<String>
    private(set) var feedbackByOutfit: [String: FeedbackKind] = [:]
    private(set) var favoriteOutfitIDs: Set<String> = []
    private(set) var feedbackTags: [Wire.FeedbackTagResponse] = []
    private(set) var appliedChip: ContextChip?
    private(set) var isRefreshing = false
    /// outfit id → recommended item id → the item the user chose instead.
    private var swaps: [String: [String: String]] = [:]
    var notice: String?

    private let api: APIClient
    private let wardrobe: WardrobeStore
    private let wornLedger = WornLedger()

    init(api: APIClient, wardrobe: WardrobeStore) {
        self.api = api
        self.wardrobe = wardrobe
        wornOutfitIDs = wornLedger.todaysOutfits()
    }

    var outfits: [Wire.OutfitResponse] { today?.outfits ?? [] }
    var isReady: Bool { today?.status == "ready" && !outfits.isEmpty }
    var weather: Wire.WeatherContextResponse? { today?.context?.weather }

    func load() async {
        if today == nil { phase = .loading }
        do {
            async let todayRequest = api.send(Endpoints.today())
            async let wardrobeLoad: Void = wardrobe.load()
            let (today, _) = try await (todayRequest, wardrobeLoad)
            apply(today)
            phase = .loaded
        } catch {
            if today == nil { phase = .failed(userMessage(for: error)) }
        }
        if feedbackTags.isEmpty {
            feedbackTags = (try? await api.send(Endpoints.feedbackTags()).tags) ?? []
        }
    }

    /// Asks for a fresh set, optionally for a stated situation.
    func refresh(chip: ContextChip? = nil) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            apply(try await api.send(Endpoints.refreshToday(chipID: chip?.id)))
            appliedChip = chip
            swaps = [:]
        } catch APIError.http(status: 429, _, _, _) {
            notice = "今天重新搭配的次数用完了"
        } catch {
            notice = userMessage(for: error)
        }
    }

    private func apply(_ today: Wire.TodayRecommendationResponse) {
        self.today = today
        favoriteOutfitIDs = Set(today.outfits?.filter { $0.isFavorited == true }.map(\.outfitId) ?? [])
    }

    // MARK: Board

    func boardItems(for outfit: Wire.OutfitResponse) -> [BoardItem] {
        let order = ["outerwear", "top", "dress", "bottom", "shoes"]
        return outfit.items.map { slot -> BoardItem in
            let itemID = swaps[outfit.outfitId]?[slot.itemId] ?? slot.itemId
            let item = wardrobe.item(itemID)
            return BoardItem(
                slotID: slot.itemId,
                itemID: itemID,
                role: item?.category ?? slot.category ?? "accessory",
                name: item?.displayName ?? slot.title ?? "单品",
                imageURL: item.flatMap(WardrobeStore.imageURL)
            )
        }
        // Dressing order, so the board and the list read top to toe.
        .sorted { (order.firstIndex(of: $0.role) ?? order.count) < (order.firstIndex(of: $1.role) ?? order.count) }
    }

    func replacements(for slot: BoardItem, in outfit: Wire.OutfitResponse) async throws -> [Wire.ReplacementCandidateResponse] {
        try await api.send(Endpoints.replacements(outfitID: outfit.outfitId, itemID: slot.slotID)).replacements
            .filter { $0.itemId != slot.itemID }
    }

    /// Swaps are local to today's page; `itemID == nil` restores the original.
    func swap(_ slot: BoardItem, to itemID: String?, in outfit: Wire.OutfitResponse) {
        swaps[outfit.outfitId, default: [:]][slot.slotID] = itemID
    }

    // MARK: Actions

    func markWorn(_ outfit: Wire.OutfitResponse) async {
        do {
            _ = try await api.send(Endpoints.markWorn(outfitID: outfit.outfitId))
            // The outfit record knows only the recommended pieces; pieces the
            // user swapped in get their own wear record.
            for item in boardItems(for: outfit) where item.isSwapped {
                try? await wardrobe.markWorn(item.itemID)
            }
            wornOutfitIDs.insert(outfit.outfitId)
            wornLedger.record(outfit.outfitId)
            await wardrobe.load()
        } catch {
            notice = userMessage(for: error)
        }
    }

    func toggleFavorite(_ outfit: Wire.OutfitResponse) async {
        let favorite = !favoriteOutfitIDs.contains(outfit.outfitId)
        do {
            _ = try await api.send(Endpoints.setFavorite(favorite, outfitID: outfit.outfitId))
            if favorite { favoriteOutfitIDs.insert(outfit.outfitId) } else { favoriteOutfitIDs.remove(outfit.outfitId) }
        } catch {
            notice = userMessage(for: error)
        }
    }

    func sendFeedback(_ kind: FeedbackKind, tags: [String], for outfit: Wire.OutfitResponse) async -> Bool {
        do {
            _ = try await api.send(Endpoints.feedback(outfitID: outfit.outfitId, type: kind, reasonTags: tags))
            feedbackByOutfit[outfit.outfitId] = kind
            notice = "记下了，下次搭配会参考"
            return true
        } catch {
            notice = userMessage(for: error)
            return false
        }
    }
}

/// Remembers which outfits were worn today so the page still says so after a
/// relaunch (the recommendation payload doesn't).
private struct WornLedger {
    private static let key = "aidrobe.today.worn"

    private var day: String { Date.now.formatted(.iso8601.year().month().day()) }

    func todaysOutfits() -> Set<String> {
        let stored = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]]
        return Set(stored?[day] ?? [])
    }

    func record(_ outfitID: String) {
        UserDefaults.standard.set([day: Array(todaysOutfits().union([outfitID]))], forKey: Self.key)
    }
}
