import AidrobeKit
import Foundation

/// The user's garments, shared by every screen so an edit in one place shows
/// everywhere. Recommendation payloads carry only item ids; names and pictures
/// come from here.
@MainActor
@Observable
final class WardrobeStore {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var items: [Wire.WardrobeItemResponse] = []

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func item(_ id: String) -> Wire.WardrobeItemResponse? {
        items.first { $0.itemId == id }
    }

    func imageURL(_ id: String) -> URL? {
        item(id).flatMap(Self.imageURL)
    }

    static func imageURL(_ item: Wire.WardrobeItemResponse) -> URL? {
        (item.coverImageUrl ?? item.originalImageUrl).flatMap(URL.init(string:))
    }

    func load() async {
        if items.isEmpty { phase = .loading }
        do {
            items = try await api.send(Endpoints.wardrobeItems()).items
            phase = .loaded
        } catch {
            if items.isEmpty { phase = .failed(userMessage(for: error)) }
        }
    }

    func reset() {
        items = []
        phase = .idle
    }

    func update(_ id: String, _ changes: Wire.UpdateWardrobeItemRequest) async throws {
        replace(try await api.send(Endpoints.updateItem(id, changes)))
    }

    func updateFit(_ id: String, _ status: Wire.FitStatus) async throws {
        replace(try await api.send(Endpoints.updateFit(id, status: status)))
    }

    func markWorn(_ id: String) async throws {
        replace(try await api.send(Endpoints.markItemWorn(id)))
    }

    func delete(_ id: String) async throws {
        _ = try await api.send(Endpoints.deleteItem(id))
        items.removeAll { $0.itemId == id }
    }

    private func replace(_ item: Wire.WardrobeItemResponse) {
        guard let index = items.firstIndex(where: { $0.itemId == item.itemId }) else { return }
        items[index] = item
    }
}
