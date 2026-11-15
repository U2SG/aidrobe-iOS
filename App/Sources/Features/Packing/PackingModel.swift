import AidrobeKit
import Foundation

/// Display copy for trips. Scene keys are the ones the backend's generator
/// knows (`SCENE_CATEGORIES`); anything else it treats as casual.
enum PackingCopy {
    static let scenes: [(key: String, title: String)] = [
        ("casual", "休闲"), ("business", "商务"), ("formal", "正式"),
        ("dinner", "聚餐"), ("sport", "运动"), ("beach", "海边"),
    ]

    static func scene(_ key: String) -> String {
        scenes.first { $0.key == key.lowercased() }?.title ?? "日常"
    }

    static func title(_ list: Wire.PackingListResponse) -> String {
        guard let destination = list.destination, !destination.isEmpty else { return "这趟出门" }
        return "去\(destination)"
    }

    /// "3 天 · 11月20日出发 · 休闲、商务"
    static func summary(_ list: Wire.PackingListResponse) -> String {
        var parts: [String] = []
        if let days = list.days { parts.append("\(days) 天") }
        if let day = Garment.day(list.departureDate) { parts.append("\(day)出发") }
        if !list.scenes.isEmpty { parts.append(list.scenes.map(scene).joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }
}

/// One garment to bring, however many days it is worn.
struct PackingPiece: Identifiable, Equatable {
    let itemID: String
    let days: [Int]
    let isPacked: Bool

    var id: String { itemID }
}

extension Wire.PackingListResponse {
    /// Unique garments in first-use order. The list stores one row per day a
    /// piece is worn; it counts as packed only when every row says so.
    var pieces: [PackingPiece] {
        var order: [String] = []
        var rows: [String: [Wire.PackingItem]] = [:]
        for item in items {
            if rows[item.itemId] == nil { order.append(item.itemId) }
            rows[item.itemId, default: []].append(item)
        }
        return order.map { id in
            let entries = rows[id] ?? []
            return PackingPiece(
                itemID: id,
                days: Array(Set(entries.map(\.day))).sorted(),
                isPacked: entries.allSatisfy { $0.packed == true }
            )
        }
    }
}

@MainActor
@Observable
final class PackingModel {
    enum Phase: Equatable {
        case loading, loaded
        /// Backend flag is off (503).
        case unavailable
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var lists: [Wire.PackingListResponse] = []
    private(set) var isCreating = false
    var notice: String?
    /// Lists with a save in flight, and lists edited since that save was sent.
    private var saving: Set<String> = []
    private var unsaved: Set<String> = []
    private var listRevision = UUID()
    private var pendingCreate: (key: Data, id: String)?
    private var expectedContexts: [String: Wire.DesignContextRef] = [:]

    private let api: APIClient
    private let accountGeneration = AccountLocalData.generation
    private var isCurrent: Bool { accountGeneration == AccountLocalData.generation && !Task.isCancelled }

    init(api: APIClient) {
        self.api = api
    }

    func list(_ id: String) -> Wire.PackingListResponse? {
        lists.first { $0.packingListId == id }
    }

    func expectedContext(for id: String) -> Wire.DesignContextRef? { expectedContexts[id] }

    func loadOne(_ id: String) async {
        guard isCurrent else { return }
        let revision = listRevision
        do {
            let list = try await api.send(Endpoints.packingList(id))
            guard isCurrent, revision == listRevision else { return }
            lists.removeAll { $0.packingListId == id }
            lists.insert(list, at: 0)
            phase = .loaded
        } catch {
            guard isCurrent else { return }
            if (error as? APIError)?.isFeatureDisabled == true { phase = .unavailable }
            else { phase = .failed(userMessage(for: error)) }
        }
    }

    func load() async {
        guard saving.isEmpty, !isCreating, isCurrent else { return }
        let revision = listRevision
        if lists.isEmpty { phase = .loading }
        do {
            let loaded = try await api.send(Endpoints.packingLists())
            // A reload started before an edit may contain an older snapshot.
            guard revision == listRevision, isCurrent else { return }
            lists = loaded
            phase = .loaded
        } catch let error as APIError where error.isFeatureDisabled {
            guard isCurrent else { return }
            phase = .unavailable
        } catch {
            guard isCurrent else { return }
            if lists.isEmpty { phase = .failed(userMessage(for: error)) }
        }
    }

    /// Returns the new list's id, or nil with `notice` set.
    func create(destination: String, days: Int, departure: Date?, scenes: [String], weather: String,
                designContext: Wire.DesignContextRef? = nil) async -> String? {
        guard !isCreating, isCurrent else { return nil }
        listRevision = UUID()
        isCreating = true
        defer { isCreating = false }
        let place = destination.trimmingCharacters(in: .whitespaces)
        let hint = weather.trimmingCharacters(in: .whitespaces)
        do {
            var request = Wire.CreatePackingListRequest(
                destination: place.isEmpty ? nil : place,
                days: days,
                scenes: scenes,
                weatherHint: hint.isEmpty ? nil : hint,
                departureDate: departure.map(Self.calendarDay)
            )
            request.designContext = designContext
            if designContext != nil {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let key = try encoder.encode(request)
                if pendingCreate?.key != key { pendingCreate = (key, UUID().uuidString) }
                request.requestId = pendingCreate?.id
            }
            let list = try await api.send(Endpoints.createPackingList(request))
            guard isCurrent else { return nil }
            lists.insert(list, at: 0)
            pendingCreate = nil
            if let designContext { expectedContexts[list.packingListId] = designContext }
            phase = .loaded
            return list.packingListId
        } catch {
            guard isCurrent else { return nil }
            notice = designContext != nil && (error as? APIError)?.status == 409
                ? "这段对话已有新修改，回去看一下，再继续。" : userMessage(for: error)
            return nil
        }
    }

    /// Ticks a garment for every day it is worn. Shown at once; saved one
    /// request at a time per list, because each save replaces the whole item
    /// list — ticks made while one is in flight go out together in the next.
    func setPacked(_ packed: Bool, itemID: String, in listID: String) async {
        guard isCurrent, let index = lists.firstIndex(where: { $0.packingListId == listID }) else { return }
        listRevision = UUID()
        var confirmed = lists[index]
        for row in lists[index].items.indices where lists[index].items[row].itemId == itemID {
            lists[index].items[row].packed = packed
        }
        guard saving.insert(listID).inserted else {
            unsaved.insert(listID)
            return
        }
        defer { saving.remove(listID) }
        repeat {
            unsaved.remove(listID)
            guard isCurrent, let current = lists.firstIndex(where: { $0.packingListId == listID }) else { return }
            do {
                var saved = try await api.send(Endpoints.updatePackingList(listID, items: lists[current].items))
                guard isCurrent else { return }
                // Keep the plan we already have if the update response leaves it out.
                if saved.plan == nil { saved.plan = confirmed.plan }
                confirmed = saved
                // Newer ticks are still only local; don't overwrite them with this response.
                if !unsaved.contains(listID), let latest = lists.firstIndex(where: { $0.packingListId == listID }) {
                    lists[latest] = saved
                }
            } catch {
                guard isCurrent else { return }
                unsaved.remove(listID)
                if let latest = lists.firstIndex(where: { $0.packingListId == listID }) { lists[latest] = confirmed }
                notice = userMessage(for: error)
                return
            }
        } while unsaved.contains(listID)
    }

    /// `yyyy-MM-dd` in the user's calendar (a departure date is a calendar day, not an instant).
    private static func calendarDay(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
