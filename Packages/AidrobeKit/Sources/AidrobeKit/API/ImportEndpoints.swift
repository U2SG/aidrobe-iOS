import Foundation

extension Endpoints {
    /// `input_type` values the backend accepts for photo imports.
    public enum ImportInputType: String, Sendable {
        case image, outfitImage = "outfit_image", screenshot
    }

    public enum ImportSourceType: String, Sendable {
        case camera, album
    }

    /// Creates an import task. `idempotencyKey` makes retries return the same task.
    /// `conversationID` links it to an Ask conversation, which then lists it.
    /// Album scans pass one `batchID` per run and the photo's day as `takenAt`
    /// (`YYYY-MM-DD`); batch tasks stay out of the pending list.
    public static func createImport(
        imageURL: String,
        inputType: ImportInputType,
        source: ImportSourceType,
        idempotencyKey: String,
        locale: String? = nil,
        conversationID: String? = nil,
        batchID: String? = nil,
        takenAt: String? = nil
    ) throws -> Endpoint<Wire.ImportTaskResponse> {
        try Endpoint(
            .post,
            "/v1/import-tasks",
            json: Wire.CreateImportTaskRequest(
                inputType: inputType.rawValue,
                sourceType: source.rawValue,
                imageUrl: imageURL,
                locale: locale,
                conversationId: conversationID,
                batchId: batchID,
                takenAt: takenAt
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    public static func pendingImportTasks(limit: Int = 20, offset: Int = 0) -> Endpoint<[Wire.ImportTaskResponse]> {
        Endpoint(.get, "/v1/import-tasks", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
    }

    public static func importTask(_ taskID: String) -> Endpoint<Wire.ImportTaskResponse> {
        Endpoint(.get, "/v1/import-tasks/\(taskID)")
    }

    public static func confirmImport(
        taskID: String,
        _ request: Wire.ConfirmImportRequest
    ) throws -> Endpoint<Wire.ConfirmImportResponse> {
        try Endpoint(.post, "/v1/import-tasks/\(taskID)/confirm", json: request)
    }

    /// Prefills the waiting candidates from the user's words (include, name,
    /// price, material). Nothing is added to the wardrobe. 409 when the task is
    /// no longer waiting; 503 leaves the candidates as they were.
    public static func applyImportNote(taskID: String, note: String) throws -> Endpoint<Wire.ImportTaskResponse> {
        try Endpoint(
            .post,
            "/v1/import-tasks/\(taskID)/apply-note",
            json: Wire.ApplyImportNoteRequest(note: note),
            timeout: Endpoint<Wire.ImportTaskResponse>.slowTimeout
        )
    }

    public static func confirmImportItems(
        taskID: String,
        _ request: Wire.ConfirmItemsRequest
    ) throws -> Endpoint<Wire.ConfirmItemsResponse> {
        try Endpoint(.post, "/v1/import-tasks/\(taskID)/confirm-items", json: request)
    }
}

extension Endpoints {
    /// Garments found across an album scan, merged per garment. Poll until `complete`.
    public static func importBatch(_ batchID: String) -> Endpoint<Wire.ImportBatchResponse> {
        Endpoint(.get, "/v1/import-batches/\(batchID)")
    }

    /// create / link / skip per group; 409 `unknown_group` / `group_confirmed` → reload.
    public static func confirmImportBatch(
        _ batchID: String, _ request: Wire.ConfirmImportBatchRequest
    ) throws -> Endpoint<Wire.ConfirmImportBatchResponse> {
        try Endpoint(.post, "/v1/import-batches/\(batchID)/confirm", json: request)
    }
}

/// Polls an import task until recognition finishes. Mirrors the RN client:
/// every 1.5 s, at most 120 s.
public enum ImportPolling {
    public enum Outcome: Sendable, Equatable {
        case waitingConfirm(Wire.ImportTaskResponse)
        case failed(code: String?, message: String?)
        case timedOut
    }

    public static func waitForRecognition(
        interval: Duration = .milliseconds(1500),
        timeout: Duration = .seconds(120),
        clock: some Clock<Duration> = ContinuousClock(),
        fetch: @Sendable () async throws -> Wire.ImportTaskResponse
    ) async throws -> Outcome {
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let task = try await fetch()
            switch task.status {
            case "waiting_confirm", "completed":
                return .waitingConfirm(task)
            case "failed":
                return .failed(code: task.errorCode, message: task.errorMessage)
            default:
                break
            }
            if clock.now.advanced(by: interval) > deadline { return .timedOut }
            try await clock.sleep(for: interval)
        }
    }
}
