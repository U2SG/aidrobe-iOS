@testable import AidrobeKit
import Foundation
import Testing

@Suite struct AlbumScanTests {
    @Test func nextRunTakesUnseenNewestFirstAndBroughtBackFirst() {
        let ids = ["a", "b", "c", "d", "e"]
        let run = AlbumScan.nextRun(newestFirst: ids, processed: ["a", "c"], reinclude: ["e"], limit: 2)
        #expect(run == ["e", "b"])
        #expect(AlbumScan.unseenCount(ids, processed: ["a", "c"]) == 3)
    }

    @Test func passersByAreNotSecondPeople() {
        #expect(AlbumScan.prominentPeople(boxAreas: []) == 0)
        #expect(AlbumScan.prominentPeople(boxAreas: [0.3, 0.01]) == 1)
        #expect(AlbumScan.prominentPeople(boxAreas: [0.3, 0.2]) == 2)
    }

    @Test func nearDuplicatesKeepTheBestShotPerDay() {
        let shots = [
            AlbumScan.Shot(day: "2026-11-03", quality: 1),
            AlbumScan.Shot(day: "2026-11-03", quality: 5),
            AlbumScan.Shot(day: "2026-11-03", quality: 2),
            AlbumScan.Shot(day: "2026-11-04", quality: 9),
            AlbumScan.Shot(day: "2026-11-03", quality: 3),
        ]
        // 0~1 and 1~2 chain; 3 is the same picture on another day; 4 is far from all.
        let distances: [Set<Int>: Float] = [[0, 1]: 0.2, [1, 2]: 0.3, [0, 2]: 0.6, [0, 3]: 0.0]
        let dropped = AlbumScan.nearDuplicates(shots) { distances[[$0, $1]] ?? 0.9 }
        #expect(dropped == [0, 2])
    }

    @Test func incomparableShotsAreNeverMerged() {
        let shots = [AlbumScan.Shot(day: "d", quality: 1), AlbumScan.Shot(day: "d", quality: 2)]
        #expect(AlbumScan.nearDuplicates(shots) { _, _ in nil }.isEmpty)
    }

    @Test func identicalPrintsForEveryPhotoMeanTheExtractorIsBroken() {
        #expect(AlbumScan.printsAreDegenerate(count: 4) { _, _ in 0.001 })
        #expect(!AlbumScan.printsAreDegenerate(count: 2) { _, _ in 0 })
        #expect(!AlbumScan.printsAreDegenerate(count: 3) { i, j -> Float? in i == 0 && j == 2 ? Float(0.6) : 0 })
    }

    @Test func sharpEdgesScoreHigherThanFlatImages() {
        let flat = [UInt8](repeating: 128, count: 16)
        let checker = (0..<16).map { UInt8(($0 + $0 / 4) % 2 == 0 ? 0 : 255) }
        #expect(AlbumScan.sharpness(gray: flat, width: 4, height: 4) == 0)
        #expect(AlbumScan.sharpness(gray: checker, width: 4, height: 4) > 0)
    }

    @Test func dayIsLocalAndNeverInTheFuture() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        // 2026-11-02 18:30 UTC is already 11-03 in Shanghai.
        let taken = Date(timeIntervalSince1970: 1_793_644_200)
        #expect(AlbumScan.day(of: taken, today: taken.addingTimeInterval(86_400), calendar: calendar) == "2026-11-03")
        #expect(AlbumScan.day(of: taken.addingTimeInterval(10 * 86_400), today: taken, calendar: calendar) == "2026-11-03")
    }

    @Test func backfillLabelListsShortDays() {
        #expect(AlbumScan.shortDay("2026-11-03") == "11/3")
        #expect(AlbumScan.backfillLabel(["2026-11-03", "2026-11-09", "2026-11-15"])
            == "按照片日期补记 3 次穿着（11/3、11/9、11/15）")
        #expect(AlbumScan.backfillLabel(["2026-11-01", "2026-11-02", "2026-11-03"], shown: 2)
            == "按照片日期补记 3 次穿着（11/1、11/2 等）")
    }

    @Test func summaryCountsSkipsByReasonInAFixedOrder() {
        #expect(AlbumScan.Tally(kept: 4).summary == "本次识别 4 张")
        let tally = AlbumScan.Tally(kept: 12, skipped: [.screenshot: 1, .duplicate: 3, .multiplePeople: 1])
        #expect(tally.summary == "本次识别 12 张，跳过 5 张（重复 3 · 多人 1 · 截图 1）")
    }

    @Test func broughtBackPhotosReturnToTheNextRun() throws {
        var ledger = AlbumScan.Ledger()
        ledger.startRun()
        ledger.skip("p1", .multiplePeople)
        ledger.skip("p2", .screenshot)
        ledger.done("p3")
        #expect(ledger.lastTally.summary == "本次识别 1 张，跳过 2 张（多人 1 · 截图 1）")
        ledger.bringBack(.screenshot)
        #expect(ledger.processed == ["p1", "p2", "p3"])
        ledger.bringBack(.multiplePeople)
        #expect(ledger.processed == ["p2", "p3"])
        #expect(ledger.reinclude == ["p1"])
        #expect(ledger.skipped(.multiplePeople).isEmpty)
        #expect(ledger.lastTally.skippedTotal == 2)
        #expect(AlbumScan.nextRun(newestFirst: ["p3", "p2", "p1"], processed: ledger.processed, reinclude: ledger.reinclude) == ["p1"])
        let decoded = try JSONDecoder().decode(AlbumScan.Ledger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }

    @Test func uncertainLookAlikesAreLeftToTheUser() {
        #expect(AlbumScan.defaultChoice(kind: "new", hasExistingItem: false) == .create)
        #expect(AlbumScan.defaultChoice(kind: "existing", hasExistingItem: true) == .link)
        #expect(AlbumScan.defaultChoice(kind: "uncertain", hasExistingItem: true) == .skip)
    }

    @Test func batchImportCarriesBatchAndDayAndBatchEndpointsDecode() async throws {
        let transport = StubTransport { request in
            switch request.url?.path {
            case "/v1/import-tasks": (202, #"{"code":0,"message":"ok","data":{"task_id":"t1","status":"queued"}}"#)
            default: (200, #"""
                {"code":0,"message":"ok","data":{"batch_id":"b","total_photos":2,"processing":0,"failed":0,"complete":true,
                "groups":[{"group_id":"g","kind":"existing","status":"pending","category":"top","color_main":"black",
                "title":"黑色西装外套","best_crop_url":null,"members":[{"task_id":"t1","temp_item_id":"c1","taken_at":"2026-11-03"}],
                "existing_item":{"item_id":"i","title":"黑色西装外套","image_url":null},"wear_dates":["2026-11-03"]}]}}
                """#)
            }
        }
        let client = APIClient(
            environment: AppEnvironment(stage: .development, apiBaseURL: URL(string: "http://api.test")!),
            tokens: TokenStore(store: InMemorySecureStore()),
            transport: transport
        )
        _ = try await client.send(Endpoints.createImport(
            imageURL: "http://x/a.jpg", inputType: .outfitImage, source: .album, idempotencyKey: "k",
            batchID: "b", takenAt: "2026-11-03"
        ))
        let body = try #require(transport.requests.first?.httpBody.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(body["batch_id"] as? String == "b")
        #expect(body["taken_at"] as? String == "2026-11-03")
        let batch = try await client.send(Endpoints.importBatch("b"))
        #expect(batch.complete && batch.groups.first?.existingItem?.title == "黑色西装外套")
        #expect(transport.requests.last?.url?.path == "/v1/import-batches/b")
    }
}
