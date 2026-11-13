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
