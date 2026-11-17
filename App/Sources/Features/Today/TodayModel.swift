import AidrobeKit
import Foundation

/// One garment in a persisted outfit version.
struct BoardItem: Identifiable, Equatable {
    let slotID: String
    let itemID: String
    let role: String
    let name: String
    let imageURL: URL?
    var usesGeneratedCover: Bool = false

    var id: String { slotID }
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
    private var wearFeedbackOutfitIDs: Set<String> = []
    private(set) var favoriteOutfitIDs: Set<String> = []
    private(set) var changingFavorites: Set<String> = []
    private(set) var feedbackTags: [Wire.FeedbackTagResponse] = []
    private(set) var appliedChip: ContextChip?
    private(set) var appliedText: String?
    private(set) var isRefreshing = false
    private(set) var isRevising = false
    private(set) var needsLatestVersion = false
    private(set) var revisedOutfitID: String?
    private(set) var generatedImages: [String: URL] = [:]
    private(set) var generatingOutfits: Set<String> = []
    private(set) var outfitImageIssues: [String: String] = [:]
    var notice: String?

    private let api: APIClient
    private let wardrobe: WardrobeStore
    private let wornLedger = WornLedger()
    private let accountGeneration = AccountLocalData.generation
    private let onRevision: (Wire.StylingResponse) -> Void
    private let onFavoritesChange: () -> Void
    private var loadID = UUID()
    private var mutationID = UUID()
    private var actionRecommendationDate: String?

    init(
        api: APIClient, wardrobe: WardrobeStore,
        onRevision: @escaping (Wire.StylingResponse) -> Void = { _ in },
        onFavoritesChange: @escaping () -> Void = {}
    ) {
        self.api = api
        self.wardrobe = wardrobe
        self.onRevision = onRevision
        self.onFavoritesChange = onFavoritesChange
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
        guard !isRefreshing, !isRevising, accountGeneration == AccountLocalData.generation else { return }
        let requestID = UUID()
        loadID = requestID
        let mutation = mutationID
        if today == nil { phase = .loading }
        do {
            async let todayRequest = api.send(Endpoints.today())
            async let wardrobeLoad: Void = wardrobe.load()
            let (today, _) = try await (todayRequest, wardrobeLoad)
            guard loadID == requestID, mutationID == mutation, accountGeneration == AccountLocalData.generation else { return }
            apply(today)
            phase = .loaded
        } catch {
            guard loadID == requestID, mutationID == mutation, accountGeneration == AccountLocalData.generation else { return }
            if Task.isCancelled { return }
            if today == nil { phase = .failed(userMessage(for: error)) }
            else if needsLatestVersion { notice = "没能读取最新搭配，请再试一次。已保存的版本仍然保留。" }
        }
        try? await loadFeedbackTags()
    }

    /// Asks for a fresh set, optionally for a stated situation.
    func refresh(chip: ContextChip? = nil, text: String? = nil) async throws {
        guard !isRefreshing, !isRevising else { return }
        let mutation = UUID()
        mutationID = mutation
        isRefreshing = true
        defer { isRefreshing = false }
        let result = try await api.send(Endpoints.refreshToday(chipID: chip?.id, text: text))
        guard mutationID == mutation, accountGeneration == AccountLocalData.generation else { return }
        apply(result)
        appliedChip = result.appliedContext == nil ? nil : chip
        appliedText = chip == nil ? result.appliedContext?.overrideText : nil
    }

    static func refreshMessage(_ error: any Error) -> String {
        switch (error as? APIError)?.status {
        case 429: "今天重新搭配的次数用完了"
        case 422: "这次没能用上你的要求。可以换个说法，或选一个快捷选项。"
        default: userMessage(for: error)
        }
    }

    private func apply(_ today: Wire.TodayRecommendationResponse) {
        self.today = today
        needsLatestVersion = false
        wornOutfitIDs = wornLedger.outfits(on: today.recommendationDate)
        favoriteOutfitIDs = Set(today.outfits?.filter { $0.isFavorited == true }.map(\.outfitId) ?? [])
    }

    /// Ask reuses the same outfit actions without manufacturing a Today response.
    func syncOutfit(_ outfit: Wire.OutfitResponse, recommendationDate: String? = nil) {
        syncFavorite(outfit)
        actionRecommendationDate = recommendationDate
        if let recommendationDate { wornOutfitIDs = wornLedger.outfits(on: recommendationDate) }
        needsLatestVersion = false
    }

    func syncFavorite(_ outfit: Wire.OutfitResponse) {
        if outfit.isFavorited == true { favoriteOutfitIDs.insert(outfit.outfitId) }
        else { favoriteOutfitIDs.remove(outfit.outfitId) }
    }

    func reloadAfterConflict() async -> Bool {
        await load()
        return !needsLatestVersion
    }

    // MARK: Board

    func boardItems(for outfit: Wire.OutfitResponse, useOriginalPhotoFallback: Bool = false) -> [BoardItem] {
        let order = ["outerwear", "top", "dress", "bottom", "shoes"]
        return outfit.items.map { slot -> BoardItem in
            let itemID = slot.itemId
            let item = wardrobe.item(itemID)
            let individualImage = item?.coverImageUrl.flatMap { cover in
                item?.cutoutStatus == "ready" || cover != item?.originalImageUrl ? URL(string: cover) : nil
            }
            let originalPhoto = useOriginalPhotoFallback ? item.flatMap(WardrobeStore.originalURL) : nil
            return BoardItem(
                slotID: slot.itemId,
                itemID: itemID,
                role: item?.category ?? slot.category ?? "accessory",
                name: item?.displayName ?? slot.title ?? "单品",
                imageURL: individualImage ?? originalPhoto,
                usesGeneratedCover: individualImage != nil && item?.cutoutStatus == "ready"
            )
        }
        // Dressing order, so the board and the list read top to toe.
        .sorted { (order.firstIndex(of: $0.role) ?? order.count) < (order.firstIndex(of: $1.role) ?? order.count) }
    }

    func loadGeneratedImage(for outfitID: String) async {
        guard generatingOutfits.insert(outfitID).inserted else { return }
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
            if (error as? APIError)?.reason == "missing_garment_reference" {
                outfitImageIssues[id] = userMessage(for: error)
                return
            }
            if (error as? APIError)?.status == 429 {
                notice = "今天的整套图生成次数已用完"
                return
            }
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
            guard !Task.isCancelled, accountGeneration == AccountLocalData.generation else { throw CancellationError() }
            switch asset.generationStatus {
            case "completed":
                if let image = asset.imageUrl.flatMap(URL.init(string:)) {
                    generatedImages[outfitID] = image
                    outfitImageIssues[outfitID] = nil
                } else if reportFailure {
                    notice = "这套搭配图暂时打不开"
                }
                return
            case "rejected_by_quality_gate":
                outfitImageIssues[outfitID] = "整套图未能通过原照比对"
                return
            case "failed":
                outfitImageIssues[outfitID] = "整套图生成失败"
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

    /// The server creates a complete new outfit version, including its Today
    /// association. No local replacement can get ahead of that saved result.
    func swap(
        _ slot: BoardItem, to itemID: String, in outfit: Wire.OutfitResponse, requestID: String
    ) async throws -> Wire.StylingResponse {
        guard !isRevising, !isRefreshing, !needsLatestVersion else { throw CancellationError() }
        let mutation = UUID()
        mutationID = mutation
        isRevising = true
        defer { isRevising = false }
        let revised: Wire.StylingResponse
        do {
            revised = try await api.send(Endpoints.reviseOutfit(
                outfitID: outfit.outfitId, itemID: slot.itemID, replacementItemID: itemID, requestID: requestID
            ))
        } catch {
            if accountGeneration == AccountLocalData.generation, (error as? APIError)?.status == 409 {
                needsLatestVersion = true
            }
            throw error
        }
        guard mutationID == mutation, accountGeneration == AccountLocalData.generation else { throw CancellationError() }
        if revised.status == .adopted, var current = today {
            current.outfits = [revised.outfit]
            current.recommendationId = revised.recommendationId
            current.revision = revised.recommendationRevision
            if let day = revised.recommendationDate { current.recommendationDate = day }
            apply(current)
        }
        syncOutfit(revised.outfit, recommendationDate: revised.recommendationDate)
        revisedOutfitID = revised.outfit.outfitId
        onRevision(revised)
        return revised
    }

    // MARK: Actions

    func markWorn(_ outfit: Wire.OutfitResponse) async {
        do {
            _ = try await api.send(Endpoints.markWorn(outfitID: outfit.outfitId))
            guard accountGeneration == AccountLocalData.generation else { return }
            wornOutfitIDs.insert(outfit.outfitId)
            if let day = today?.recommendationDate ?? actionRecommendationDate { wornLedger.record(outfit.outfitId, on: day) }
            await wardrobe.load()
        } catch {
            notice = userMessage(for: error)
        }
    }

    @discardableResult
    func toggleFavorite(_ outfit: Wire.OutfitResponse) async -> Bool {
        guard changingFavorites.insert(outfit.outfitId).inserted else { return false }
        defer { changingFavorites.remove(outfit.outfitId) }
        let favorite = !favoriteOutfitIDs.contains(outfit.outfitId)
        do {
            _ = try await api.send(Endpoints.setFavorite(favorite, outfitID: outfit.outfitId))
            guard accountGeneration == AccountLocalData.generation else { return false }
            if favorite { favoriteOutfitIDs.insert(outfit.outfitId) } else { favoriteOutfitIDs.remove(outfit.outfitId) }
            onFavoritesChange()
            return true
        } catch {
            notice = userMessage(for: error)
            return false
        }
    }

    func sendFeedback(_ kind: FeedbackKind, tags: [String], for outfit: Wire.OutfitResponse) async -> Bool {
        do {
            _ = try await api.send(Endpoints.feedback(outfitID: outfit.outfitId, type: kind, reasonTags: tags))
            guard accountGeneration == AccountLocalData.generation else { return false }
            feedbackByOutfit[outfit.outfitId] = kind
            notice = "记下了，下次搭配会参考"
            return true
        } catch {
            notice = userMessage(for: error)
            return false
        }
    }

    func loadFeedbackTags() async throws {
        guard accountGeneration == AccountLocalData.generation else { throw CancellationError() }
        guard feedbackTags.isEmpty else { return }
        let loaded = try await api.send(Endpoints.feedbackTags())
        guard accountGeneration == AccountLocalData.generation else { throw CancellationError() }
        feedbackTags = loaded.tags
    }

    func hasWearFeedback(outfitID: String) -> Bool {
        wearFeedbackOutfitIDs.contains(outfitID)
    }

    @discardableResult
    func loadWearFeedback(outfitID: String) async throws -> Wire.WearFeedbackRecord? {
        guard accountGeneration == AccountLocalData.generation else { throw CancellationError() }
        let snapshot = try await api.send(Endpoints.wearFeedback(outfitID: outfitID))
        guard accountGeneration == AccountLocalData.generation else { throw CancellationError() }
        if snapshot.feedback != nil { wearFeedbackOutfitIDs.insert(outfitID) }
        return snapshot.feedback
    }

    func saveWearFeedback(outfitID: String, feedback: Wire.WearFeedbackRecord) async throws {
        guard accountGeneration == AccountLocalData.generation else { throw CancellationError() }
        let snapshot = try await api.send(Endpoints.saveWearFeedback(outfitID: outfitID, feedback: feedback))
        guard accountGeneration == AccountLocalData.generation else { throw CancellationError() }
        if snapshot.feedback != nil { wearFeedbackOutfitIDs.insert(outfitID) }
        notice = "已记下这版的穿着感受"
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
