import AidrobeKit
import UIKit

/// One earlier question, kept on the device so it can be reopened. The decision
/// itself is replayed from the server's snapshot; `call` (what the user decided
/// to do) has no backend field yet and lives only here.
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
    /// Server copy, frozen with the decision.
    let text: String
    var call: Call?

    var id: String { decisionID }
}

@MainActor
@Observable
final class ShouldIBuyModel {
    enum Phase {
        case idle
        case working(String)
        /// Parsing has not finished in time; the candidate is kept so the user can look again.
        case stillWorking(candidateID: String)
        case decided(Wire.WardrobeDecisionResponse)
        /// Backend flag is off (503).
        case unavailable
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var photo: UIImage?
    private(set) var parsed: Wire.ParsedItemModel?
    private(set) var history: [AskedPurchase]
    var concern: Wire.DecisionRequest.ConcernPayload = .none
    let designContext: Wire.DesignContextRef?
    private(set) var contextConflict = false
    private(set) var pendingCandidateID: String?

    private let api: APIClient
    private let uploader: PresignedUploader
    private let accountGeneration = AccountLocalData.generation
    private static let historyKey = AccountLocalData.purchaseHistoryKey

    init(api: APIClient, designContext: Wire.DesignContextRef? = nil) {
        self.api = api
        self.designContext = designContext
        uploader = PresignedUploader(api: api)
        history = UserDefaults.standard.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([AskedPurchase].self, from: $0) } ?? []
    }

    func startOver() {
        phase = .idle
        photo = nil
        parsed = nil
        contextConflict = false
        pendingCandidateID = nil
    }

    /// Photo → upload → candidate → decision.
    func ask(about image: UIImage) async {
        guard accountGeneration == AccountLocalData.generation, !Task.isCancelled else { return }
        photo = image
        parsed = nil
        pendingCandidateID = nil
        guard let data = ImageCompressor.jpegData(from: image) else {
            return phase = .failed("这张图读不出来，换一张试试")
        }
        phase = .working("正在上传…")
        await run {
            let upload = try await self.uploader.upload(
                data, fileName: "\(UUID().uuidString).jpg", contentType: "image/jpeg"
            )
            try self.requireCurrentAccount()
            self.phase = .working("正在看这件衣服…")
            let candidate = try await self.api.send(Endpoints.createPurchaseCandidate(objectKey: upload.objectKey))
            try self.requireCurrentAccount()
            try await self.settle(candidate)
        }
    }

    /// Looks again at a candidate whose parsing had not finished.
    func resume(candidateID: String) async {
        phase = .working("正在看这件衣服…")
        await run { try await self.settle(self.api.send(Endpoints.purchaseCandidate(candidateID))) }
    }

    /// Reopens an earlier decision exactly as it was written.
    func replay(_ asked: AskedPurchase) async {
        await replay(decisionID: asked.decisionID)
    }

    func replay(decisionID: String) async {
        guard accountGeneration == AccountLocalData.generation, !Task.isCancelled else { return }
        photo = nil
        parsed = nil
        pendingCandidateID = nil
        phase = .working("正在取回当时的判断…")
        await run {
            let decision = try await self.api.send(Endpoints.wardrobeDecision(decisionID))
            try self.requireCurrentAccount()
            self.phase = .decided(decision)
        }
    }

    func call(for decisionID: String) -> AskedPurchase.Call? {
        history.first { $0.decisionID == decisionID }?.call
    }

    func setCall(_ call: AskedPurchase.Call?, for decisionID: String) {
        guard let index = history.firstIndex(where: { $0.decisionID == decisionID }) else { return }
        history[index].call = call
        persist()
    }

    func forget(_ asked: AskedPurchase) {
        history.removeAll { $0.id == asked.id }
        persist()
    }

    // MARK: Steps

    /// Parsing is usually done when the candidate is created, but `submitted`
    /// (and any status this build doesn't know) must not spin forever.
    private func settle(_ first: Wire.PurchaseCandidateResponse) async throws {
        try requireCurrentAccount()
        var candidate = first
        pendingCandidateID = candidate.id
        var attempts = 0
        while candidate.status == .submitted {
            guard attempts < 12 else { return phase = .stillWorking(candidateID: candidate.id) }
            attempts += 1
            try await Task.sleep(for: .seconds(1.5))
            try requireCurrentAccount()
            candidate = try await api.send(Endpoints.purchaseCandidate(candidate.id))
        }
        try requireCurrentAccount()
        parsed = candidate.parsedItem
        // `parse_failed` still gets a decision: the backend answers
        // "insufficient information" with a reason instead of an error.
        phase = .working("正在和你的衣橱对照…")
        let decision = try await decide(candidate.id)
        try requireCurrentAccount()
        pendingCandidateID = nil
        remember(decision)
        phase = .decided(decision)
    }

    private func decide(_ candidateID: String) async throws -> Wire.WardrobeDecisionResponse {
        try requireCurrentAccount()
        do {
            return try await api.send(Endpoints.decide(candidateID: candidateID, concern: concern, designContext: designContext))
        } catch APIError.http(status: 404, _, _, _) {
            // A decision asked for right after creation can miss the new
            // candidate once; it is there a moment later.
            try await Task.sleep(for: .seconds(1))
            try requireCurrentAccount()
            return try await api.send(Endpoints.decide(candidateID: candidateID, concern: concern, designContext: designContext))
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        do {
            try requireCurrentAccount()
            try await work()
        } catch is CancellationError {
            return
        } catch let error as APIError where error.isFeatureDisabled {
            guard accountGeneration == AccountLocalData.generation else { return }
            phase = .unavailable
        } catch let error as APIError where error.status == 409 && designContext != nil {
            guard accountGeneration == AccountLocalData.generation else { return }
            contextConflict = true
            phase = .failed("这段对话已有新修改，回去看一下，再继续。")
        } catch APIError.decoding {
            guard accountGeneration == AccountLocalData.generation else { return }
            // A status or verdict this build doesn't know (version skew).
            phase = .failed("这次的结果这个版本还看不懂，更新后再试")
        } catch {
            guard accountGeneration == AccountLocalData.generation else { return }
            phase = .failed(userMessage(for: error))
        }
    }

    private func requireCurrentAccount() throws {
        guard accountGeneration == AccountLocalData.generation, !Task.isCancelled else { throw CancellationError() }
    }

    private func remember(_ decision: Wire.WardrobeDecisionResponse) {
        guard !history.contains(where: { $0.decisionID == decision.id }) else { return }
        history.insert(
            AskedPurchase(decisionID: decision.id, askedAt: decision.createdAt, text: decision.decisionText, call: nil),
            at: 0
        )
        history = Array(history.prefix(30))
        persist()
    }

    private func persist() {
        guard accountGeneration == AccountLocalData.generation else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
    }
}
