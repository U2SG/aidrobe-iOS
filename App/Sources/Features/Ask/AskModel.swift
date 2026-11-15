import AidrobeKit
import Foundation

struct AskGarment: Identifiable, Equatable {
    let id: String
    let name: String
    let imageURL: URL?
    let isInWardrobe: Bool
}

@MainActor
@Observable
final class AskModel {
    struct Entry: Identifiable {
        enum State {
            case asking
            case answered(sessionID: String?, text: String, garments: [AskGarment])
            case unavailable
            case failed(String)
        }

        let id: UUID
        let question: String
        var state: State
        var feedback: FeedbackKind?
        var styling: Wire.StylingResponse?
        var requestID: String
        var conversationID: String?
        var expectedRevision: Int?
        var baseOutfitID: String?
        var needsRebase = false

        init(
            id: UUID = UUID(), question: String, state: State, styling: Wire.StylingResponse? = nil,
            conversationID: String? = nil, expectedRevision: Int? = nil, baseOutfitID: String? = nil
        ) {
            self.id = id
            self.question = question
            self.state = state
            self.styling = styling
            self.requestID = id.uuidString
            self.conversationID = conversationID
            self.expectedRevision = expectedRevision
            self.baseOutfitID = baseOutfitID
        }
    }

    private enum DesignAction {
        case adopt, toggleLock(String), removeExclusion(String)
    }

    private(set) var entries: [Entry] = []
    private(set) var history: [Wire.AskHistoryItem] = []
    private(set) var styling: Wire.StylingResponse?
    private(set) var baseOutfit: Wire.OutfitResponse?
    private(set) var conversationID: String?
    private(set) var isRestoring = false
    private(set) var isUpdatingDesign = false
    private(set) var restorationFailure: String?
    private(set) var actionFailure: String?
    private(set) var needsLatestVersion = false
    var notice: String?

    let outfitActions: TodayModel
    private let api: APIClient
    private let wardrobe: WardrobeStore
    private let bookmark: ConversationBookmark?
    private let onRevision: (Wire.StylingResponse) -> Void
    private let accountGeneration = AccountLocalData.generation
    private var epoch = UUID()
    private var restoringID: String?
    private var actionRequestIDs: [String: String] = [:]
    private var retryAction: DesignAction?

    init(
        api: APIClient, wardrobe: WardrobeStore, bookmark: ConversationBookmark? = nil,
        onRevision: @escaping (Wire.StylingResponse) -> Void = { _ in }
    ) {
        self.api = api
        self.wardrobe = wardrobe
        self.bookmark = bookmark
        self.onRevision = onRevision
        outfitActions = TodayModel(api: api, wardrobe: wardrobe, onRevision: onRevision)
    }

    var isAsking: Bool {
        entries.contains { if case .asking = $0.state { true } else { false } }
    }

    var isBusy: Bool { isAsking || isRestoring || isUpdatingDesign || outfitActions.isRevising }
    var canRetryAction: Bool { retryAction != nil && !needsLatestVersion }
    var canRetryRestore: Bool { restoringID != nil || conversationID != nil }
    var lockedItemIDs: [String] { styling?.constraints.lockedItemIds ?? [] }
    var excludedItemIDs: [String] { styling?.constraints.excludedItemIds ?? [] }

    var earlier: [Wire.AskHistoryItem] {
        let shown = Set(entries.compactMap { entry -> String? in
            if case let .answered(sessionID, _, _) = entry.state { sessionID } else { nil }
        })
        return history.filter { !shown.contains($0.askSessionId) && !($0.answer ?? "").isEmpty }
    }

    func load() async {
        guard !isBusy, accountGeneration == AccountLocalData.generation else { return }
        let expectedEpoch = epoch
        async let wardrobeLoad: Void = wardrobe.items.isEmpty ? wardrobe.load() : ()
        if let loaded = try? await api.send(Endpoints.askHistory()), isCurrent(expectedEpoch) { history = loaded }
        await wardrobeLoad
        guard isCurrent(expectedEpoch), !isBusy, !Task.isCancelled else { return }
        if baseOutfit != nil, conversationID == nil { return }
        if let saved = bookmark?.conversationID, saved != conversationID || entries.isEmpty {
            await restore(saved)
        } else if let conversationID {
            await refreshStyling(conversationID)
        }
    }

    func ask(_ raw: String) async {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy, !needsLatestVersion else { return }
        let entry = Entry(
            question: question, state: .asking, conversationID: conversationID,
            expectedRevision: styling?.revision ?? (conversationID == nil ? nil : 0),
            baseOutfitID: baseOutfit?.outfitId
        )
        entries.append(entry)
        await send(entry.id)
    }

    private func send(_ entryID: UUID) async {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        let expectedEpoch = epoch
        do {
            let answer = try await api.send(Endpoints.ask(
                entry.question, conversationID: entry.conversationID, requestID: entry.requestID,
                expectedRevision: entry.expectedRevision, baseOutfitID: entry.baseOutfitID
            ))
            guard isCurrent(expectedEpoch), let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
            entries[index].state = .answered(
                sessionID: answer.askSessionId, text: answer.answer,
                garments: garments(ids: answer.itemRefs, snapshots: answer.itemRefSnapshots ?? [])
            )
            entries[index].styling = answer.styling
            baseOutfit = nil
            conversationID = answer.conversationId ?? conversationID
            if let result = answer.styling { acceptRevision(result) }
            if let conversationID { bookmark?.save(conversationID) }
        } catch {
            guard isCurrent(expectedEpoch), let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
            if (error as? APIError)?.isFeatureDisabled == true {
                entries[index].state = .unavailable
            } else if (error as? APIError)?.status == 409 {
                entries[index].needsRebase = true
                entries[index].state = .failed("这套已有新修改。先看当前方案，再决定是否重试这句话。")
                if let conversationID { await refreshStyling(conversationID) }
            } else {
                entries[index].state = .failed(userMessage(for: error))
            }
        }
    }

    func retry(_ entry: Entry) async {
        guard !isBusy, !needsLatestVersion,
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        if entries[index].needsRebase {
            entries[index].requestID = UUID().uuidString
            entries[index].conversationID = conversationID
            entries[index].expectedRevision = styling?.revision
            entries[index].baseOutfitID = nil
            entries[index].needsRebase = false
        }
        entries[index].state = .asking
        await send(entry.id)
    }

    func startOver() async {
        guard !isBusy else { return }
        resetConversation()
        await load()
    }

    /// Opening a saved outfit is local context only; the user's first question
    /// creates a design session. No empty prompt or LLM bootstrap is sent.
    func beginDesign(from outfit: Wire.OutfitResponse) {
        if styling?.outfit.outfitId == outfit.outfitId { return }
        resetConversation()
        baseOutfit = outfit
    }

    private func resetConversation() {
        epoch = UUID()
        entries = []
        styling = nil
        baseOutfit = nil
        conversationID = nil
        restoringID = nil
        restorationFailure = nil
        actionFailure = nil
        needsLatestVersion = false
        isRestoring = false
        isUpdatingDesign = false
        actionRequestIDs = [:]
        retryAction = nil
        bookmark?.save(nil)
    }

    func reopen(_ item: Wire.AskHistoryItem) async {
        guard !isBusy else { return }
        if let id = item.conversationId {
            await restore(id)
        } else {
            resetConversation()
            entries = [Entry(
                question: item.question,
                state: .answered(
                    sessionID: item.askSessionId, text: item.answer ?? "",
                    garments: garments(ids: item.itemRefs ?? [], snapshots: item.itemRefSnapshots ?? [])
                ), styling: item.styling
            )]
        }
    }

    func retryRestore() async {
        guard !isBusy else { return }
        if let id = restoringID { await restore(id) }
        else if let conversationID { await refreshStyling(conversationID) }
    }

    func restoreCurrent() async -> Bool {
        guard !isBusy, let conversationID else { return false }
        await restore(conversationID)
        return restorationFailure == nil && !needsLatestVersion
    }

    private func restore(_ id: String) async {
        let expectedEpoch = UUID()
        epoch = expectedEpoch
        isRestoring = true
        restoringID = id
        restorationFailure = nil
        defer { if epoch == expectedEpoch { isRestoring = false } }
        do {
            let result = try await api.send(Endpoints.askConversation(id))
            guard isCurrent(expectedEpoch), !Task.isCancelled else { return }
            var restored: [Entry] = []
            var question: String?
            for message in result.messages ?? [] {
                if message.role == "user" { question = message.content }
                else if message.role == "assistant" {
                    let ids = message.styling?.outfit.items.map(\.itemId) ?? []
                    restored.append(Entry(
                        id: UUID(uuidString: message.id) ?? UUID(),
                        question: question ?? "调整后的搭配",
                        state: .answered(
                            sessionID: message.askSessionId, text: message.content,
                            garments: garments(ids: ids, snapshots: [])
                        ), styling: message.styling
                    ))
                    question = nil
                }
            }
            entries = restored
            conversationID = result.conversationId
            baseOutfit = nil
            styling = result.styling
            if let result = result.styling {
                outfitActions.syncOutfit(result.outfit, recommendationDate: result.recommendationDate)
            }
            bookmark?.save(result.conversationId)
            restorationFailure = nil
            actionFailure = nil
            needsLatestVersion = false
            restoringID = nil
            actionRequestIDs = [:]
            retryAction = nil
        } catch {
            guard isCurrent(expectedEpoch) else { return }
            if Task.isCancelled { return }
            needsLatestVersion = true
            restorationFailure = userMessage(for: error)
            if [403, 404].contains((error as? APIError)?.status ?? 0) {
                bookmark?.save(nil)
                restoringID = nil
                restorationFailure = "这段对话暂时无法继续，可以重新说说你的想法。"
            }
        }
    }

    /// Refreshes the authoritative version without discarding a failed question
    /// which the user may want to retry against that new version.
    private func refreshStyling(_ id: String) async {
        let expectedEpoch = epoch
        do {
            let result = try await api.send(Endpoints.askConversation(id))
            guard isCurrent(expectedEpoch), conversationID == id, !Task.isCancelled else { return }
            if let result = result.styling { acceptRevision(result) }
            else { styling = nil }
            needsLatestVersion = false
            restorationFailure = nil
        } catch {
            guard isCurrent(expectedEpoch) else { return }
            if Task.isCancelled { return }
            needsLatestVersion = true
            restorationFailure = "没能读取这套的最新修改。请重试，已经保存的方案仍然保留。"
        }
    }

    func acceptRevision(_ result: Wire.StylingResponse) {
        guard accountGeneration == AccountLocalData.generation else { return }
        if let styling, styling.conversationId == result.conversationId, styling.revision > result.revision { return }
        let isNewRevision = styling?.conversationId != result.conversationId || styling?.revision != result.revision
        styling = result
        conversationID = result.conversationId
        outfitActions.syncOutfit(result.outfit, recommendationDate: result.recommendationDate)
        bookmark?.save(result.conversationId)
        actionFailure = nil
        needsLatestVersion = false
        if isNewRevision {
            actionRequestIDs = [:]
            retryAction = nil
        }
    }

    func adopt() async { await perform(.adopt) }
    func toggleLock(_ itemID: String) async { await perform(.toggleLock(itemID)) }
    func removeExclusion(_ itemID: String) async { await perform(.removeExclusion(itemID)) }

    func retryDesignAction() async {
        if let retryAction { await perform(retryAction) }
    }

    private func perform(_ action: DesignAction) async {
        guard !isBusy, !needsLatestVersion, let current = styling else { return }
        let expectedEpoch = epoch
        let key = "\(current.conversationId)|\(current.revision)|\(String(describing: action))"
        let requestID = actionRequestIDs[key] ?? UUID().uuidString
        actionRequestIDs[key] = requestID
        retryAction = action
        isUpdatingDesign = true
        actionFailure = nil
        defer { if epoch == expectedEpoch { isUpdatingDesign = false } }
        do {
            let endpoint: Endpoint<Wire.StylingResponse>
            switch action {
            case .adopt:
                endpoint = try Endpoints.adoptStyling(
                    conversationID: current.conversationId, revision: current.revision,
                    requestID: requestID, date: current.constraints.targetDate
                )
            case let .toggleLock(itemID):
                var ids = Set(current.constraints.lockedItemIds ?? [])
                if !ids.insert(itemID).inserted { ids.remove(itemID) }
                endpoint = try Endpoints.reviseStylingConstraints(
                    conversationID: current.conversationId, revision: current.revision,
                    lockedItemIDs: ids.sorted(), requestID: requestID
                )
            case let .removeExclusion(itemID):
                endpoint = try Endpoints.reviseStylingConstraints(
                    conversationID: current.conversationId, revision: current.revision,
                    excludedItemIDs: (current.constraints.excludedItemIds ?? []).filter { $0 != itemID },
                    requestID: requestID
                )
            }
            let result = try await api.send(endpoint)
            guard isCurrent(expectedEpoch) else { return }
            acceptRevision(result)
            onRevision(result)
            if case .adopt = action {
                if let day = result.recommendationDate, day != JournalDay.today {
                    notice = "已安排在\(Garment.day(day) ?? day)，回来还能接着调整"
                } else { notice = "已放到今日，回来还能接着调整" }
            }
        } catch {
            guard isCurrent(expectedEpoch) else { return }
            if (error as? APIError)?.status == 409 {
                retryAction = nil
                await refreshStyling(current.conversationId)
                actionFailure = "这套已有新修改，请根据最新方案重新选择。"
            } else { actionFailure = userMessage(for: error) }
        }
    }

    func canGiveFeedback(_ entry: Entry) -> Bool {
        if case let .answered(sessionID, _, _) = entry.state { return sessionID != nil || entry.styling != nil }
        return false
    }

    func sendFeedback(_ kind: FeedbackKind, for entry: Entry) async {
        guard case let .answered(sessionID, _, _) = entry.state else { return }
        let expectedEpoch = epoch
        do {
            if let outfitID = entry.styling?.outfit.outfitId {
                _ = try await api.send(Endpoints.feedback(outfitID: outfitID, type: kind))
            } else if let sessionID {
                _ = try await api.send(Endpoints.askFeedback(sessionID: sessionID, type: kind))
            } else { return }
            guard isCurrent(expectedEpoch), let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[index].feedback = kind
        } catch { if isCurrent(expectedEpoch) { notice = userMessage(for: error) } }
    }

    func itemName(_ id: String) -> String {
        wardrobe.item(id)?.displayName ?? styling?.outfit.items.first(where: { $0.itemId == id })?.title ?? "这件单品"
    }

    private func isCurrent(_ expectedEpoch: UUID) -> Bool {
        epoch == expectedEpoch && accountGeneration == AccountLocalData.generation
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
