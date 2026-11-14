import AidrobeKit
import Foundation

/// A garment an answer points at. Prefers the live wardrobe item; falls back to
/// the snapshot the answer carried (the item may have been removed since).
struct AskGarment: Identifiable, Equatable {
    let id: String
    let name: String
    let imageURL: URL?
    /// False once the item is no longer in the wardrobe, so it can't be opened.
    let isInWardrobe: Bool
}

@MainActor
@Observable
final class AskModel {
    struct Entry: Identifiable {
        enum State {
            case asking
            case answered(sessionID: String, text: String, garments: [AskGarment])
            /// The backend has no answering model configured (503).
            case unavailable
            case failed(String)
        }

        let id = UUID()
        let question: String
        var state: State
        var feedback: FeedbackKind?
    }

    /// The conversation on the page, oldest first.
    private(set) var entries: [Entry] = []
    private(set) var history: [Wire.AskHistoryItem] = []
    var notice: String?

    private var conversationID: String?
    private let api: APIClient
    private let wardrobe: WardrobeStore

    init(api: APIClient, wardrobe: WardrobeStore) {
        self.api = api
        self.wardrobe = wardrobe
    }

    var isAsking: Bool {
        entries.contains { if case .asking = $0.state { true } else { false } }
    }

    /// Earlier questions that are not already part of the conversation on the page.
    var earlier: [Wire.AskHistoryItem] {
        let shown = Set(entries.compactMap { entry -> String? in
            if case let .answered(sessionID, _, _) = entry.state { sessionID } else { nil }
        })
        return history.filter { !shown.contains($0.askSessionId) && !($0.answer ?? "").isEmpty }
    }

    func load() async {
        async let wardrobeLoad: Void = wardrobe.items.isEmpty ? wardrobe.load() : ()
        if let history = try? await api.send(Endpoints.askHistory()) { self.history = history }
        await wardrobeLoad
    }

    func ask(_ raw: String) async {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        entries.append(Entry(question: question, state: .asking))
        let index = entries.count - 1
        do {
            let answer = try await api.send(Endpoints.ask(question, conversationID: conversationID))
            conversationID = answer.conversationId ?? conversationID
            entries[index].state = .answered(
                sessionID: answer.askSessionId,
                text: answer.answer,
                garments: garments(ids: answer.itemRefs, snapshots: answer.itemRefSnapshots ?? [])
            )
        } catch let error as APIError where error.isFeatureDisabled {
            entries[index].state = .unavailable
        } catch {
            entries[index].state = .failed(userMessage(for: error))
        }
    }

    /// Asks the same question again after a failure, in place.
    /// Clears the page for a fresh conversation; what was asked stays in "之前问过".
    func startOver() async {
        entries = []
        conversationID = nil
        await load()
    }

    func retry(_ entry: Entry) async {
        entries.removeAll { $0.id == entry.id }
        await ask(entry.question)
    }

    /// Brings an earlier question and its answer back onto the page.
    func reopen(_ item: Wire.AskHistoryItem) {
        entries.append(Entry(
            question: item.question,
            state: .answered(
                sessionID: item.askSessionId,
                text: item.answer ?? "",
                garments: garments(ids: item.itemRefs ?? [], snapshots: item.itemRefSnapshots ?? [])
            )
        ))
    }

    func sendFeedback(_ kind: FeedbackKind, for entry: Entry) async {
        guard case let .answered(sessionID, _, _) = entry.state,
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        do {
            _ = try await api.send(Endpoints.askFeedback(sessionID: sessionID, type: kind))
            entries[index].feedback = kind
        } catch {
            notice = userMessage(for: error)
        }
    }

    private func garments(ids: [String], snapshots: [Wire.AskItemRefSnapshot]) -> [AskGarment] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.compactMap { id in
            if let item = wardrobe.item(id) {
                return AskGarment(id: id, name: item.displayName, imageURL: WardrobeStore.imageURL(item), isInWardrobe: true)
            }
            guard let snapshot = snapshots.first(where: { $0.itemId == id }) else { return nil }
            return AskGarment(
                id: id, name: snapshot.name, imageURL: snapshot.thumbnailUrl.flatMap(URL.init(string:)), isInWardrobe: false
            )
        }
    }
}
