import AidrobeKit
import Foundation

/// A calendar month, the unit the journal pages through.
struct JournalMonth: Hashable {
    var year: Int
    var month: Int

    static var current: JournalMonth {
        let parts = Calendar.current.dateComponents([.year, .month], from: .now)
        return JournalMonth(year: parts.year ?? 2026, month: parts.month ?? 1)
    }

    var title: String { "\(year)年\(month)月" }

    func shifted(by months: Int) -> JournalMonth {
        let index = year * 12 + (month - 1) + months
        return JournalMonth(year: index / 12, month: index % 12 + 1)
    }

    /// `yyyy-MM-dd`, the form the API uses for calendar days.
    func key(day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var numberOfDays: Int {
        Calendar.current.range(of: .day, in: .month, for: firstDay)?.count ?? 30
    }

    /// Empty cells before the 1st in a Monday-first week.
    var leadingBlanks: Int {
        (Calendar.current.component(.weekday, from: firstDay) + 5) % 7
    }

    private var firstDay: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now
    }
}

/// Display helpers for the API's calendar days (`yyyy-MM-dd`). These are days,
/// not instants, so they are read by their parts and never through a time zone.
enum JournalDay {
    static func parts(_ raw: String) -> (year: Int, month: Int, day: Int)? {
        let numbers = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        return numbers.count == 3 ? (numbers[0], numbers[1], numbers[2]) : nil
    }

    static func weekday(_ raw: String) -> String {
        guard let parts = parts(raw),
              let date = Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
        else { return "" }
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[Calendar.current.component(.weekday, from: date) - 1]
    }

    static var today: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

@MainActor
@Observable
final class JournalModel {
    enum Phase: Equatable {
        case loading, loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var entries: [Wire.OutfitHistoryEntry] = []
    private(set) var total = 0
    private(set) var isLoadingMore = false
    private(set) var markedDays: [JournalMonth: Set<String>] = [:]
    private(set) var outfits: [String: Wire.OutfitResponse] = [:]
    private(set) var feedbackLabels: [String: String] = [:]
    var month = JournalMonth.current
    var notice: String?

    private let api: APIClient
    private let wardrobe: WardrobeStore
    private var page = 0
    private var requestedOutfits: Set<String> = []
    private static let pageSize = 30

    init(api: APIClient, wardrobe: WardrobeStore) {
        self.api = api
        self.wardrobe = wardrobe
    }

    var hasMore: Bool { entries.count < total }

    func load() async {
        do {
            async let history = api.send(Endpoints.outfitHistory(page: 1, pageSize: Self.pageSize))
            async let wardrobeLoad: Void = wardrobe.items.isEmpty ? wardrobe.load() : ()
            let (first, _) = try await (history, wardrobeLoad)
            entries = first.items
            total = first.total
            page = 1
            phase = .loaded
        } catch {
            if entries.isEmpty { phase = .failed(userMessage(for: error)) }
        }
        await loadMarks()
        if feedbackLabels.isEmpty, let tags = try? await api.send(Endpoints.feedbackTags()).tags {
            feedbackLabels = Dictionary(tags.map { ($0.key, $0.labelZhCn) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.send(Endpoints.outfitHistory(page: page + 1, pageSize: Self.pageSize))
            let known = Set(entries.map(\.wearHistoryId))
            entries += next.items.filter { !known.contains($0.wearHistoryId) }
            total = next.total
            page += 1
        } catch {
            notice = userMessage(for: error)
        }
    }

    /// Days with a record in the shown month; fetched once per month.
    func loadMarks() async {
        let month = month
        guard markedDays[month] == nil else { return }
        if let dates = try? await api.send(Endpoints.outfitCalendar(year: month.year, month: month.month)).dates {
            markedDays[month] = Set(dates.map { String($0.prefix(10)) })
        }
    }

    /// The record for a calendar day: from the loaded pages, else from the server.
    func entry(on day: String) async -> Wire.OutfitHistoryEntry? {
        if let loaded = entries.first(where: { $0.wornDate.hasPrefix(day) }) { return loaded }
        do {
            return try await api.send(Endpoints.outfitRecord(wornDate: day))
        } catch {
            notice = userMessage(for: error)
            return nil
        }
    }

    // MARK: Pieces

    /// History entries don't list their pieces; fetch the outfit once per id.
    func loadOutfit(for entry: Wire.OutfitHistoryEntry) async {
        guard let id = entry.outfit?.outfitId, requestedOutfits.insert(id).inserted else { return }
        if let outfit = try? await api.send(Endpoints.outfit(id)) {
            outfits[id] = outfit
        } else {
            requestedOutfits.remove(id)
        }
    }

    /// Nil while the pieces are still loading (or could not be loaded).
    func boardItems(for entry: Wire.OutfitHistoryEntry) -> [BoardItem]? {
        guard let id = entry.outfit?.outfitId, let outfit = outfits[id] else { return nil }
        let order = ["outerwear", "top", "dress", "bottom", "shoes"]
        return outfit.items.map { slot -> BoardItem in
            let item = wardrobe.item(slot.itemId)
            return BoardItem(
                slotID: slot.itemId,
                itemID: slot.itemId,
                role: item?.category ?? slot.category ?? "accessory",
                // A piece removed from the wardrobe since then keeps its place in the record.
                name: item?.displayName ?? slot.title ?? "已不在衣橱里的单品",
                imageURL: item.flatMap(WardrobeStore.imageURL)
            )
        }
        .sorted { (order.firstIndex(of: $0.role) ?? order.count) < (order.firstIndex(of: $1.role) ?? order.count) }
    }

    func isInWardrobe(_ item: BoardItem) -> Bool {
        wardrobe.item(item.itemID) != nil
    }

    // MARK: Copy

    static func feeling(_ raw: String?) -> String? {
        switch raw.flatMap(FeedbackKind.init(rawValue:)) {
        case .love, .like: "挺好"
        case .dislike: "不太合适"
        default: nil
        }
    }

    func reasons(_ entry: Wire.OutfitHistoryEntry) -> [String] {
        (entry.reasonTags ?? []).compactMap { feedbackLabels[$0] }
    }
}
