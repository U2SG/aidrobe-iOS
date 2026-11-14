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
    var usesGeneratedCover: Bool = false

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
    private(set) var wornOutfitIDs: Set<String> = []
    private(set) var feedbackByOutfit: [String: FeedbackKind] = [:]
    private(set) var favoriteOutfitIDs: Set<String> = []
    private(set) var feedbackTags: [Wire.FeedbackTagResponse] = []
    private(set) var appliedChip: ContextChip?
    private(set) var isRefreshing = false
    private(set) var generatedImages: [String: URL] = [:]
    private(set) var generatingOutfits: Set<String> = []
    private(set) var rejectedOutfitImages: Set<String> = []
    /// outfit id → recommended item id → the item the user chose instead.
    private var swaps: [String: [String: String]] = [:]
    var notice: String?

    private let api: APIClient
    private let wardrobe: WardrobeStore
    private let wornLedger = WornLedger()

    init(api: APIClient, wardrobe: WardrobeStore) {
        self.api = api
        self.wardrobe = wardrobe
    }

    var outfits: [Wire.OutfitResponse] { today?.outfits ?? [] }
    var isReady: Bool { today?.status == "ready" && !outfits.isEmpty }
    var weather: Wire.WeatherContextResponse? {
        #if DEBUG
        if let staged = Self.stagedWeather { return staged }
        #endif
        return today?.context?.weather
    }

    #if DEBUG
    /// `-aidrobe.debug.weather "小雨,12,8.5,30,80,东北风"` — condition, °C, then optionally
    /// hour, wind km/h, humidity % and wind direction — stages a sky for screenshots
    /// when the backend has no weather provider.
    private static var staged: [Substring] {
        UserDefaults.standard.string(forKey: "aidrobe.debug.weather")?.split(separator: ",", omittingEmptySubsequences: false) ?? []
    }

    private static var stagedWeather: Wire.WeatherContextResponse? {
        let parts = staged
        guard parts.count >= 2, let temperature = Double(parts[1]) else { return nil }
        return Wire.WeatherContextResponse(
            temperatureC: temperature,
            feelsLikeC: temperature - 2,
            rainProbability: parts[0].contains("雨") ? 0.8 : 0.1,
            condition: String(parts[0]),
            humidity: parts.count > 4 ? Int(parts[4]) : nil,
            windDir: parts.count > 5 ? String(parts[5]) : nil,
            windSpeed: parts.count > 3 ? Double(parts[3]) : nil,
            locationName: "上海"
        )
    }
    #endif

    /// The light to lay over the page, when there is weather to show.
    var sky: WeatherVisual? {
        guard let weather else { return nil }
        #if DEBUG
        if Self.staged.count > 2, let hour = Double(Self.staged[2]) { return WeatherVisual(weather, hour: hour) }
        #endif
        return WeatherVisual(weather)
    }

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
        wornOutfitIDs = wornLedger.outfits(on: today.recommendationDate)
        favoriteOutfitIDs = Set(today.outfits?.filter { $0.isFavorited == true }.map(\.outfitId) ?? [])
    }

    // MARK: Board

    func boardItems(for outfit: Wire.OutfitResponse) -> [BoardItem] {
        let order = ["outerwear", "top", "dress", "bottom", "shoes"]
        return outfit.items.map { slot -> BoardItem in
            let itemID = swaps[outfit.outfitId]?[slot.itemId] ?? slot.itemId
            let item = wardrobe.item(itemID)
            let individualImage = item?.coverImageUrl.flatMap { cover in
                item?.cutoutStatus == "ready" || cover != item?.originalImageUrl ? URL(string: cover) : nil
            }
            return BoardItem(
                slotID: slot.itemId,
                itemID: itemID,
                role: item?.category ?? slot.category ?? "accessory",
                name: item?.displayName ?? slot.title ?? "单品",
                imageURL: individualImage,
                usesGeneratedCover: item?.cutoutStatus == "ready"
            )
        }
        // Dressing order, so the board and the list read top to toe.
        .sorted { (order.firstIndex(of: $0.role) ?? order.count) < (order.firstIndex(of: $1.role) ?? order.count) }
    }

    func loadGeneratedImage(for outfitID: String) async {
        guard generatedImages[outfitID] == nil,
              !rejectedOutfitImages.contains(outfitID),
              generatingOutfits.insert(outfitID).inserted else { return }
        defer { generatingOutfits.remove(outfitID) }
        do {
            let asset = try await api.send(Endpoints.generatedOutfitImage(outfitID))
            try await displayImage(asset, for: outfitID, reportFailure: false)
        } catch {
            // This lookup is optional. A first-time outfit has no generated asset.
        }
    }

    func generateImage(for outfit: Wire.OutfitResponse) async {
        let id = outfit.outfitId
        guard generatingOutfits.insert(id).inserted else { return }
        defer { generatingOutfits.remove(id) }
        do {
            let asset = try await api.send(Endpoints.generateOutfitImage(id))
            try await displayImage(asset, for: id, reportFailure: true)
        } catch {
            if Task.isCancelled { return }
            notice = (error as? APIError)?.isFeatureDisabled == true
                ? "当前服务还没有开启搭配生图"
                : userMessage(for: error)
        }
    }

    private func displayImage(
        _ firstAsset: Wire.OutfitVisualAssetResponse, for outfitID: String, reportFailure: Bool
    ) async throws {
        var asset = firstAsset
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(230))
        while clock.now < deadline {
            switch asset.generationStatus {
            case "completed":
                if let image = asset.imageUrl.flatMap(URL.init(string:)) {
                    generatedImages[outfitID] = image
                } else if reportFailure {
                    notice = "这套搭配图暂时打不开"
                }
                return
            case "rejected_by_quality_gate":
                rejectedOutfitImages.insert(outfitID)
                if reportFailure { notice = "整套图未通过核对，已显示单品参考图" }
                return
            case "failed":
                if reportFailure { notice = "这次没能生成搭配图" }
                return
            default:
                try await clock.sleep(for: .seconds(3))
                asset = try await api.send(Endpoints.outfitVisual(asset.assetId))
            }
        }
        if reportFailure { notice = "搭配图还在生成，稍后可以再打开" }
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
        let accountGeneration = AccountLocalData.generation
        do {
            _ = try await api.send(Endpoints.markWorn(outfitID: outfit.outfitId))
            // The outfit record knows only the recommended pieces; pieces the
            // user swapped in get their own wear record.
            for item in boardItems(for: outfit) where item.isSwapped {
                guard accountGeneration == AccountLocalData.generation else { return }
                try? await wardrobe.markWorn(item.itemID)
            }
            guard accountGeneration == AccountLocalData.generation else { return }
            wornOutfitIDs.insert(outfit.outfitId)
            if let day = today?.recommendationDate { wornLedger.record(outfit.outfitId, on: day) }
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

/// Remembers which outfits were worn on the current recommendation day so the
/// page still says so after a relaunch (the recommendation payload doesn't).
/// Keyed by the server's `recommendation_date`, never the device's idea of today.
@MainActor
private struct WornLedger {
    private static let key = AccountLocalData.wornTodayKey

    func outfits(on day: String) -> Set<String> {
        let stored = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]]
        return Set(stored?[day] ?? [])
    }

    func record(_ outfitID: String, on day: String) {
        UserDefaults.standard.set([day: Array(outfits(on: day).union([outfitID]))], forKey: Self.key)
    }
}
