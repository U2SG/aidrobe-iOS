import AidrobeKit
import Foundation

/// Today's state: the recommendation plus the wardrobe items it references
/// (the recommendation payload carries no image URLs).
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
    private(set) var itemsByID: [String: Wire.WardrobeItemResponse] = [:]
    private(set) var wornOutfitIDs: Set<String> = []
    private(set) var feedbackByOutfit: [String: FeedbackKind] = [:]
    var notice: String?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    var outfits: [Wire.OutfitResponse] { today?.outfits ?? [] }
    var isReady: Bool { today?.status == "ready" && !outfits.isEmpty }

    func load() async {
        if today == nil { phase = .loading }
        do {
            async let todayRequest = api.send(Endpoints.today())
            async let itemsRequest = api.send(Endpoints.wardrobeItems())
            let (today, items) = try await (todayRequest, itemsRequest)
            self.today = today
            itemsByID = Dictionary(items.items.map { ($0.itemId, $0) }, uniquingKeysWith: { first, _ in first })
            phase = .loaded
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func markWorn(_ outfit: Wire.OutfitResponse) async {
        do {
            _ = try await api.send(Endpoints.markWorn(outfitID: outfit.outfitId))
            wornOutfitIDs.insert(outfit.outfitId)
            notice = "已记录今天穿这套"
        } catch {
            notice = Self.message(for: error)
        }
    }

    func sendFeedback(_ kind: FeedbackKind, reasons: [FeedbackReason], for outfit: Wire.OutfitResponse) async {
        do {
            _ = try await api.send(Endpoints.feedback(outfitID: outfit.outfitId, type: kind, reasons: reasons))
            feedbackByOutfit[outfit.outfitId] = kind
            notice = "收到，下次推荐会参考"
        } catch {
            notice = Self.message(for: error)
        }
    }

    func imageURL(for item: Wire.RecommendationItemResponse) -> URL? {
        guard let raw = itemsByID[item.itemId]?.coverImageUrl ?? itemsByID[item.itemId]?.originalImageUrl else {
            return nil
        }
        return URL(string: raw)
    }

    func displayName(for item: Wire.RecommendationItemResponse) -> String {
        itemsByID[item.itemId]?.displayName ?? item.title ?? "单品"
    }

    static func message(for error: any Error) -> String {
        switch error {
        case APIError.network: "网络异常，请检查后端是否在运行"
        case let APIError.business(_, message): message.isEmpty ? "请求失败" : message
        case let APIError.http(status, _, message, _): message ?? "请求失败（\(status)）"
        case APIError.unauthorized: "登录已过期"
        default: "请求失败"
        }
    }
}
