import Foundation
import Testing
@testable import AidrobeKit

@Suite struct ImportTests {
    private static func task(_ status: String, error: String? = nil) -> Wire.ImportTaskResponse {
        Wire.ImportTaskResponse(taskId: "t1", status: status, errorCode: error)
    }

    @Test func createSendsIdempotencyKey() async throws {
        let transport = StubTransport { _ in (202, #"{"code":0,"message":"ok","data":{"task_id":"t1","status":"queued"}}"#) }
        let client = APIClient(
            environment: AppEnvironment(stage: .development, apiBaseURL: URL(string: "http://api.test")!),
            tokens: TokenStore(store: InMemorySecureStore()),
            transport: transport
        )
        let created = try await client.send(
            Endpoints.createImport(imageURL: "http://x/a.jpg", inputType: .image, source: .album, idempotencyKey: "k-1")
        )
        #expect(created.taskId == "t1")
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "k-1")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["input_type"] as? String == "image")
        #expect(body["source_type"] as? String == "album")
        #expect(body["image_url"] as? String == "http://x/a.jpg")
    }

    @Test func askImportLinksConversationAndAppliesNote() async throws {
        let transport = StubTransport { _ in
            (200, #"{"code":0,"message":"ok","data":{"task_id":"t1","status":"waiting_confirm","candidate_items":[{"title":"Cardigan","display_name":"羊毛开衫","category":"top","color_main":"grey","confidence_score":0.9,"original_image_url":"http://x/a.jpg","temp_item_id":"c1","should_import":true,"purchase_price":"399.00","material":"羊毛","visibility":"partially_hidden"}]}}"#)
        }
        let client = APIClient(
            environment: AppEnvironment(stage: .development, apiBaseURL: URL(string: "http://api.test")!),
            tokens: TokenStore(store: InMemorySecureStore()),
            transport: transport
        )
        _ = try await client.send(Endpoints.createImport(
            imageURL: "http://x/a.jpg", inputType: .outfitImage, source: .album, idempotencyKey: "k-1",
            conversationID: "11111111-1111-1111-1111-111111111111"
        ))
        let task = try await client.send(Endpoints.applyImportNote(taskID: "t1", note: "开衫是羊毛的，399 块"))
        let candidate = try #require(task.candidateItems?.first)
        #expect(candidate.purchasePrice == "399.00")
        #expect(candidate.material == "羊毛")
        #expect(candidate.visibility == "partially_hidden")

        let create = try #require(transport.requests.first?.httpBody.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(create["conversation_id"] as? String == "11111111-1111-1111-1111-111111111111")
        #expect(create["input_type"] as? String == "outfit_image")
        let note = try #require(transport.requests.last)
        #expect(note.url?.path == "/v1/import-tasks/t1/apply-note")
        let noteBody = try #require(note.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(noteBody["note"] as? String == "开衫是羊毛的，399 块")
    }

    @Test func confirmItemsSendsPriceAndMaterial() throws {
        let item = Wire.ConfirmItemInput(
            tempItemId: "c1", title: "羊毛开衫", category: "top", colorMain: "grey",
            purchasePrice: .init(value2: "399"), material: "羊毛"
        )
        let data = try JSONEncoder().encode(Wire.ConfirmItemsRequest(items: [item], dismissRemaining: true))
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try #require((body["items"] as? [[String: Any]])?.first)
        #expect(first["purchase_price"] as? String == "399")
        #expect(first["material"] as? String == "羊毛")
        #expect(body["dismiss_remaining"] as? Bool == true)
    }

    @Test func pollingStopsWhenRecognised() async throws {
        let responses = Responses([Self.task("queued"), Self.task("processing"), Self.task("waiting_confirm")])
        let outcome = try await ImportPolling.waitForRecognition(interval: .milliseconds(1)) { await responses.next() }
        #expect(outcome == .waitingConfirm(Self.task("waiting_confirm")))
        #expect(await responses.calls == 3)
    }

    @Test func pollingReportsFailure() async throws {
        let responses = Responses([Self.task("failed", error: "vision_failed")])
        let outcome = try await ImportPolling.waitForRecognition(interval: .milliseconds(1)) { await responses.next() }
        #expect(outcome == .failed(code: "vision_failed", message: nil))
    }

    @Test func pollingTimesOut() async throws {
        let responses = Responses([Self.task("processing")])
        let outcome = try await ImportPolling.waitForRecognition(
            interval: .milliseconds(5), timeout: .milliseconds(20)
        ) { await responses.next() }
        #expect(outcome == .timedOut)
    }
}

/// Returns queued responses in order, repeating the last one.
actor Responses {
    private var queue: [Wire.ImportTaskResponse]
    private(set) var calls = 0

    init(_ queue: [Wire.ImportTaskResponse]) { self.queue = queue }

    func next() -> Wire.ImportTaskResponse {
        calls += 1
        return queue.count > 1 ? queue.removeFirst() : queue[0]
    }
}
