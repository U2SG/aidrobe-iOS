import AidrobeKit
import UIKit

/// Navigation context for a new evaluation. A saved decision always displays
/// its own server snapshot instead of these potentially newer conditions.
struct ShoppingDesignSource {
    let conversationID: String
    let revision: Int
    let constraints: Wire.StylingConstraints
}

/// A local index of server decisions. Older device-only choices remain readable
/// but are never presented as a choice that has been saved to the conversation.
struct AskedPurchase: Codable, Identifiable, Equatable {
    enum Call: String, Codable, CaseIterable {
        case buy, skip, later

        var title: String {
            switch self {
            case .buy: "打算买"
            case .skip: "这次不买"
            case .later: "再想想"
            }
        }
    }

    let decisionID: String
    let askedAt: Date
    let text: String
    var call: Call?
    var choiceSynced: Bool? = nil

    var id: String { decisionID }
}

@MainActor
@Observable
final class ShouldIBuyModel {
    enum Phase {
        case idle
        case working(String)
        case stillWorking(candidateID: String)
        case reviewingLatest
        case decided(Wire.WardrobeDecisionResponse)
        case unavailable
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var photo: UIImage?
    private(set) var parsed: Wire.ParsedItemModel?
    private(set) var history: [AskedPurchase]
    private(set) var source: ShoppingDesignSource?
    private(set) var needsLatestDesign = false
    private(set) var isSavingChoice = false
    private(set) var choiceFailure: String?
    var concern: Wire.DecisionRequest.ConcernPayload = .none

    private let api: APIClient
    private let uploader: PresignedUploader
    private let onDecision: (Wire.WardrobeDecisionResponse) -> Void
    private let accountGeneration = AccountLocalData.generation
    private static let historyKey = AccountLocalData.purchaseHistoryKey
    private var epoch = UUID()
    private var uploadedObjectKey: String?
    private var candidateID: String?
    private var candidateRequestID: String?
    private var replayDecisionID: String?
    private var requestID: String?
    private var requestConcern: Wire.DecisionRequest.ConcernPayload = .none
    private var choiceToRetry: (decisionID: String, call: AskedPurchase.Call?)?

    private var isCurrent: Bool { accountGeneration == AccountLocalData.generation && !Task.isCancelled }
    var isBusy: Bool { if case .working = phase { true } else { false } }
    var canRetry: Bool { photo != nil || uploadedObjectKey != nil || candidateID != nil || replayDecisionID != nil }
    var evaluationConcern: Wire.DecisionRequest.ConcernPayload { requestConcern }

    init(
        api: APIClient, source: ShoppingDesignSource? = nil,
        onDecision: @escaping (Wire.WardrobeDecisionResponse) -> Void = { _ in }
    ) {
        self.api = api
        self.source = source
        self.onDecision = onDecision
        uploader = PresignedUploader(api: api)
        history = UserDefaults.standard.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([AskedPurchase].self, from: $0) } ?? []
    }

    func startOver() {
        guard isCurrent, !isBusy, !isSavingChoice else { return }
        epoch = UUID()
        phase = .idle
        photo = nil
        parsed = nil
        uploadedObjectKey = nil
        candidateID = nil
        candidateRequestID = nil
        replayDecisionID = nil
        requestID = nil
        needsLatestDesign = false
        choiceFailure = nil
        choiceToRetry = nil
    }

    /// Keep each completed step. A decision retry never uploads the image or
    /// creates another candidate once its ID has been received.
    func ask(about image: UIImage) async {
        guard isCurrent, !isBusy, !isSavingChoice else { return }
        startOver()
        photo = image
        requestConcern = concern
        candidateRequestID = UUID().uuidString
        requestID = source == nil ? nil : UUID().uuidString
        await evaluate()
    }

    func retry() async {
        guard isCurrent, !isBusy else { return }
        if needsLatestDesign { await reloadDesign(); return }
        if let replayDecisionID { await replay(decisionID: replayDecisionID); return }
        await evaluate()
    }

    func resume(candidateID: String) async {
        guard isCurrent, !isBusy, self.candidateID == candidateID else { return }
        await evaluate()
    }

    /// A conflict does not silently change the meaning of a request. Fetch the
    /// latest brief, show it, then let the user start a new evaluation explicitly.
    func reloadDesign() async {
        guard isCurrent, !isBusy, let source else { return }
        let expectedEpoch = epoch
        phase = .working("正在读取这次的新条件…")
        await run(expectedEpoch) {
            let conversation = try await self.api.send(Endpoints.askConversation(source.conversationID))
            try self.requireCurrent(expectedEpoch)
            guard conversation.conversationId == source.conversationID,
                  let revision = conversation.designBrief?.revision ?? conversation.styling?.revision,
                  let constraints = conversation.designBrief?.constraints ?? conversation.styling?.constraints else {
                throw PurchaseReceiptError("这段对话的条件暂时取不回来。候选图片已经保留，可以再试一次。")
            }
            self.source = ShoppingDesignSource(
                conversationID: source.conversationID, revision: revision, constraints: constraints
            )
            self.phase = .reviewingLatest
        }
    }

    func evaluateLatest() async {
        guard isCurrent, !isBusy, case .reviewingLatest = phase else { return }
        requestID = UUID().uuidString
        needsLatestDesign = false
        await evaluate()
    }

    func replay(_ asked: AskedPurchase) async { await replay(decisionID: asked.decisionID) }

    /// Read by immutable decision ID; this never recomputes against today's brief.
    func replay(decisionID: String) async {
        guard isCurrent, !isBusy, !isSavingChoice else { return }
        startOver()
        replayDecisionID = decisionID
        let expectedEpoch = epoch
        phase = .working("正在取回当时的判断…")
        await run(expectedEpoch) {
            let decision = try await self.api.send(Endpoints.wardrobeDecision(decisionID))
            try self.requireCurrent(expectedEpoch)
            guard decision.id == decisionID else { throw PurchaseReceiptError.mismatched }
            self.receive(decision)
        }
    }

    func call(for decisionID: String) -> AskedPurchase.Call? {
        guard case let .decided(decision) = phase, decision.id == decisionID else { return nil }
        return decision.choice.flatMap { AskedPurchase.Call(rawValue: $0.rawValue) }
    }

    func setCall(_ call: AskedPurchase.Call?, for decisionID: String) async {
        guard isCurrent, !isSavingChoice, case let .decided(current) = phase,
              current.id == decisionID else { return }
        let expectedEpoch = epoch
        isSavingChoice = true
        choiceFailure = nil
        choiceToRetry = (decisionID, call)
        defer { if epoch == expectedEpoch { isSavingChoice = false } }
        do {
            let decision = try await api.send(Endpoints.setPurchaseChoice(
                call.flatMap { .init(rawValue: $0.rawValue) }, decisionID: decisionID
            ))
            try requireCurrent(expectedEpoch)
            guard decision.id == current.id, decision.candidateId == current.candidateId,
                  decision.designContext?.conversationId == current.designContext?.conversationId,
                  decision.designContext?.revision == current.designContext?.revision,
                  decision.choice?.rawValue == call?.rawValue else { throw PurchaseReceiptError.mismatched }
            choiceToRetry = nil
            receive(decision)
        } catch {
            guard isCurrent, epoch == expectedEpoch else { return }
            choiceFailure = "选择还没保存。\(userMessage(for: error))"
        }
    }

    func retryChoice() async {
        guard let pending = choiceToRetry else { return }
        await setCall(pending.call, for: pending.decisionID)
    }

    func forget(_ asked: AskedPurchase) {
        guard isCurrent else { return }
        history.removeAll { $0.id == asked.id }
        persist()
    }

    // MARK: Steps

    private func evaluate() async {
        guard isCurrent, !isBusy, !needsLatestDesign else { return }
        let expectedEpoch = epoch
        phase = .working("正在看这件衣服…")
        await run(expectedEpoch) {
            let candidate: Wire.PurchaseCandidateResponse
            if let id = self.candidateID {
                candidate = try await self.api.send(Endpoints.purchaseCandidate(id))
            } else {
                if self.uploadedObjectKey == nil {
                    guard let photo = self.photo, let data = ImageCompressor.jpegData(from: photo) else {
                        throw PurchaseReceiptError("这张图读不出来，换一张试试。")
                    }
                    self.phase = .working("正在上传…")
                    let upload = try await self.uploader.upload(
                        data, fileName: "\(UUID().uuidString).jpg", contentType: "image/jpeg"
                    )
                    // Upload has its own transport. Check the account before
                    // the shared API can send anything with replacement tokens.
                    try self.requireCurrent(expectedEpoch)
                    self.uploadedObjectKey = upload.objectKey
                }
                guard let objectKey = self.uploadedObjectKey else { throw PurchaseReceiptError.mismatched }
                self.phase = .working("正在看这件衣服…")
                candidate = try await self.api.send(Endpoints.createPurchaseCandidate(
                    objectKey: objectKey, requestID: self.candidateRequestID
                ))
            }
            try self.requireCurrent(expectedEpoch)
            self.candidateID = candidate.id
            try await self.settle(candidate, epoch: expectedEpoch)
        }
    }

    private func settle(_ first: Wire.PurchaseCandidateResponse, epoch expectedEpoch: UUID) async throws {
        try requireCurrent(expectedEpoch)
        var candidate = first
        var attempts = 0
        while candidate.status == .submitted {
            guard attempts < 12 else { return phase = .stillWorking(candidateID: candidate.id) }
            attempts += 1
            try await Task.sleep(for: .seconds(1.5))
            try requireCurrent(expectedEpoch)
            candidate = try await api.send(Endpoints.purchaseCandidate(candidate.id))
            try requireCurrent(expectedEpoch)
        }
        parsed = candidate.parsedItem
        phase = .working(source == nil ? "正在和你的衣橱对照…" : "正在按这次的条件看…")
        let endpoint = try Endpoints.decide(
            candidateID: candidate.id, concern: requestConcern,
            conversationID: source?.conversationID, expectedRevision: source?.revision, requestID: requestID
        )
        let decision: Wire.WardrobeDecisionResponse
        do { decision = try await api.send(endpoint) }
        catch APIError.http(status: 404, _, _, _) {
            try await Task.sleep(for: .seconds(1))
            try requireCurrent(expectedEpoch)
            decision = try await api.send(endpoint)
        }
        try requireCurrent(expectedEpoch)
        guard decision.candidateId == candidate.id,
              decision.designContext?.conversationId == source?.conversationID,
              decision.designContext?.revision == source?.revision else { throw PurchaseReceiptError.mismatched }
        receive(decision)
    }

    private func run(_ expectedEpoch: UUID, _ work: @escaping () async throws -> Void) async {
        do {
            try requireCurrent(expectedEpoch)
            try await work()
        } catch is CancellationError {
            return
        } catch let error as APIError where error.isFeatureDisabled {
            guard isCurrent, epoch == expectedEpoch else { return }
            phase = .unavailable
        } catch let error as APIError where error.status == 409 && source != nil && replayDecisionID == nil {
            guard isCurrent, epoch == expectedEpoch else { return }
            needsLatestDesign = true
            phase = .failed("这段对话刚有了新条件。图片和关注点都已保留，读一下最新条件后再看这件。")
        } catch APIError.decoding {
            guard isCurrent, epoch == expectedEpoch else { return }
            phase = .failed("这次的结果这个版本还看不懂，更新后再试。图片已经保留。")
        } catch {
            guard isCurrent, epoch == expectedEpoch else { return }
            phase = .failed((error as? PurchaseReceiptError)?.message ?? userMessage(for: error))
        }
    }

    private func requireCurrent(_ expectedEpoch: UUID) throws {
        guard isCurrent, epoch == expectedEpoch else { throw CancellationError() }
    }

    private func receive(_ decision: Wire.WardrobeDecisionResponse) {
        let entry = AskedPurchase(
            decisionID: decision.id, askedAt: decision.createdAt, text: decision.decisionText,
            call: decision.choice.flatMap { AskedPurchase.Call(rawValue: $0.rawValue) }, choiceSynced: true
        )
        history.removeAll { $0.decisionID == decision.id }
        history.insert(entry, at: 0)
        history = Array(history.prefix(30))
        persist()
        phase = .decided(decision)
        onDecision(decision)
    }

    private func persist() {
        guard accountGeneration == AccountLocalData.generation else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
    }
}

private struct PurchaseReceiptError: Error {
    let message: String
    init(_ message: String) { self.message = message }
    static let mismatched = PurchaseReceiptError("收到的结果和这次请求不一致。候选已经保留，请重试。")
}
