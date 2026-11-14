import AidrobeKit
import Foundation

@MainActor
@Observable
final class InsightsModel {
    enum Phase: Equatable {
        case loading, loaded
        case failed(String)
    }

    struct ColorShare: Identifiable, Equatable {
        let key: String
        let count: Int
        var id: String { key }
    }

    private(set) var phase: Phase = .loading
    private(set) var summary: Wire.InsightsSummaryResponse?
    private(set) var health: Wire.WardrobeHealthResponse?
    private(set) var topItems: [Wire.TopItemResponse] = []
    private(set) var idleItems: [Wire.IdleItemResponse] = []
    private(set) var colors: [ColorShare] = []
    private(set) var costs: [Wire.CostPerWearItem] = []

    private let api: APIClient
    private let wardrobe: WardrobeStore

    init(api: APIClient, wardrobe: WardrobeStore) {
        self.api = api
        self.wardrobe = wardrobe
    }

    /// The summary decides whether the page can open; every other section is
    /// optional and simply stays out when its request fails.
    func load() async {
        async let health = try? api.send(Endpoints.wardrobeHealth())
        async let top = try? api.send(Endpoints.topItems())
        async let idle = try? api.send(Endpoints.idleItems())
        async let palette = try? api.send(Endpoints.colorPalette())
        async let costs = try? api.send(Endpoints.costPerWear())
        async let wardrobeLoad: Void = wardrobe.items.isEmpty ? wardrobe.load() : ()
        do {
            summary = try await api.send(Endpoints.insightsSummary())
            phase = .loaded
        } catch {
            if summary == nil { phase = .failed(userMessage(for: error)) }
        }
        self.health = await health ?? self.health
        topItems = (await top ?? topItems).filter { $0.wearCount > 0 }
        idleItems = await idle ?? idleItems
        if let palette = await palette {
            colors = palette.palette.additionalProperties
                .map { ColorShare(key: $0.key, count: $0.value) }
                .sorted { $0.count == $1.count ? $0.key < $1.key : $0.count > $1.count }
        }
        self.costs = (await costs ?? self.costs).filter { $0.costPerWear != nil }
        await wardrobeLoad
    }

    /// Pictures come from the wardrobe so they go through the same cutout cache.
    func imageURL(itemID: String, fallback: String?) -> URL? {
        wardrobe.imageURL(itemID) ?? fallback.flatMap(URL.init(string:))
    }

    func isInWardrobe(_ itemID: String) -> Bool {
        wardrobe.item(itemID) != nil
    }

    // MARK: Copy

    var healthVerdict: String {
        switch health?.level {
        case "high": "衣橱用得很充分"
        case "medium": "大体用得上，还有余地"
        default: "还有不少衣服没穿到"
        }
    }

    /// One plain sentence per finding, most pressing first.
    var healthFindings: [String] {
        let rank = ["high": 0, "medium": 1, "low": 2]
        return (health?.insights ?? [])
            .sorted { (rank[$0.severity] ?? 3) < (rank[$1.severity] ?? 3) }
            .compactMap { Self.finding(type: $0._type, severity: $0.severity) }
    }

    private static func finding(type: String, severity: String) -> String? {
        switch (type, severity) {
        case ("wear_coverage", "high"): "近三个月只穿到了一小部分衣服"
        case ("wear_coverage", "medium"): "近三个月穿到了大约一半的衣服"
        case ("wear_coverage", _): "大部分衣服近三个月都穿到了"
        case ("unused_items", "high"): "不少衣服两个月以上没有动过"
        case ("unused_items", "medium"): "有几件衣服两个月以上没穿"
        case ("unused_items", _): "几乎没有闲置的衣服"
        case ("category_balance", "high"): "某一类衣服明显偏多"
        case ("category_balance", "medium"): "各类衣服的数量有些不均"
        case ("category_balance", _): "各类衣服的数量比较均衡"
        default: nil
        }
    }
}
