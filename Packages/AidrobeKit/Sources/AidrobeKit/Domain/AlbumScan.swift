import Foundation

/// Rules for scanning one chosen album. Everything that can be decided on the
/// phone (and costs nothing) is decided here before a photo is uploaded; only
/// photos that pass reach the vision model.
public enum AlbumScan {
    /// Photos looked at per run, newest first (cost and waiting-time cap).
    public static let photosPerRun = 60
    /// Shorter side below this is too small to recognise garments from.
    public static let minShortSide = 600
    /// Feature-print distance under which two photos from the same day count
    /// as the same shot. Tuned on the E1 mirror selfies with the print taken on
    /// the person: same outfit ≈ 0.40, different outfits in the same room ≥ 0.55.
    public static let duplicateDistance: Float = 0.45
    /// A person whose box is smaller than this share of the largest one is a
    /// passer-by in the background, not a second subject.
    public static let prominentPersonShare = 0.15
    /// Image-classifier labels (Vision taxonomy) that mean "there are clothes in
    /// this photo", for photos without a person in them (flat-lays).
    public static let garmentLabels: Set<String> = [
        "clothing", "textile", "jacket", "jeans", "suit", "hoodie", "kimono", "sari", "swimsuit",
        "wedding_dress", "bathrobe", "scarf", "sock", "glove", "necktie", "bowtie", "hat", "beanie",
        "baseball_hat", "sunhat", "cowboy_hat", "footwear", "shoes", "sneaker", "boot", "high_heel",
        "sandal", "bag", "backpack", "purse",
    ]
    public static let garmentConfidence: Float = 0.2

    public enum SkipReason: String, Codable, CaseIterable, Sendable {
        case duplicate, multiplePeople, screenshot, video, tooSmall, noGarment, unreadable

        public var label: String {
            switch self {
            case .duplicate: "重复"
            case .multiplePeople: "多人"
            case .screenshot: "截图"
            case .video: "视频"
            case .tooSmall: "太小"
            case .noGarment: "没看到衣物"
            case .unreadable: "读取失败"
            }
        }

        /// Judgement calls the user may overrule; the rest are facts about the file.
        public var canReinclude: Bool {
            switch self {
            case .duplicate, .multiplePeople, .noGarment: true
            case .screenshot, .video, .tooSmall, .unreadable: false
            }
        }
    }

    /// The photos to look at this run: not seen before, newest first. Photos the
    /// user asked to bring back go first so the cap never pushes them out.
    public static func nextRun(
        newestFirst ids: [String], processed: Set<String>, reinclude: Set<String>, limit: Int = photosPerRun
    ) -> [String] {
        let fresh = ids.filter { !processed.contains($0) }
        let back = fresh.filter { reinclude.contains($0) }
        let rest = fresh.filter { !reinclude.contains($0) }
        return Array((back + rest).prefix(limit))
    }

    /// Unseen photos in the album (the "N 张新照片" prompt).
    public static func unseenCount(_ ids: [String], processed: Set<String>) -> Int {
        ids.reduce(0) { $0 + (processed.contains($1) ? 0 : 1) }
    }

    /// People that are subjects of the photo, from Vision's human-box areas.
    public static func prominentPeople(boxAreas: [Double]) -> Int {
        guard let largest = boxAreas.max(), largest > 0 else { return 0 }
        return boxAreas.filter { $0 >= largest * prominentPersonShare }.count
    }

    /// Variance of the 4-neighbour Laplacian on a grayscale image: higher is sharper.
    public static func sharpness(gray: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count >= width * height else { return 0 }
        var sum = 0.0
        var squares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let value = 4 * Double(gray[i]) - Double(gray[i - 1]) - Double(gray[i + 1])
                    - Double(gray[i - width]) - Double(gray[i + width])
                sum += value
                squares += value * value
                count += 1
            }
        }
        let mean = sum / count
        return squares / count - mean * mean
    }

    public struct Shot: Sendable, Equatable {
        public var day: String
        /// Higher wins within a group of near-duplicates (sharpness × pixels).
        public var quality: Double

        public init(day: String, quality: Double) {
            self.day = day
            self.quality = quality
        }
    }

    /// Indices of shots to drop as near-duplicates. Shots of the same day whose
    /// distance is under `threshold` are chained into one group (single link);
    /// each group keeps its highest-quality shot. `distance` returns nil when
    /// two shots can't be compared, which never merges them.
    public static func nearDuplicates(
        _ shots: [Shot], threshold: Float = duplicateDistance, distance: (Int, Int) -> Float?
    ) -> Set<Int> {
        var parent = Array(shots.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in shots.indices {
            for j in shots.indices where j > i && shots[i].day == shots[j].day {
                if let d = distance(i, j), d < threshold { parent[root(j)] = root(i) }
            }
        }
        var best: [Int: Int] = [:]
        for i in shots.indices {
            let r = root(i)
            if let current = best[r], shots[current].quality >= shots[i].quality { continue }
            best[r] = i
        }
        return Set(shots.indices).subtracting(best.values)
    }

    /// True when three or more prints are all practically the same: the
    /// extractor is not looking at the photos (the simulator's CPU path returns
    /// one fixed vector), so near-duplicate checks must not run on them.
    public static func printsAreDegenerate(count: Int, distance: (Int, Int) -> Float?) -> Bool {
        guard count >= 3 else { return false }
        for i in 0..<count {
            for j in (i + 1)..<count {
                guard let d = distance(i, j), d < 0.01 else { return false }
            }
        }
        return true
    }

    // MARK: Dates

    /// The photo's local calendar day as `YYYY-MM-DD`, never later than today
    /// (a wrong camera clock must not log a wear in the future).
    public static func day(of date: Date, today: Date = .now, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: min(date, today))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `2026-11-03` → `11/3`.
    public static func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        return "\(parts[1])/\(parts[2])"
    }

    /// "按照片日期补记 3 次穿着（11/3、11/9、11/15）"; long lists end in "等".
    public static func backfillLabel(_ days: [String], shown: Int = 4) -> String {
        let listed = days.prefix(shown).map(shortDay).joined(separator: "、")
        let more = days.count > shown ? " 等" : ""
        return "按照片日期补记 \(days.count) 次穿着（\(listed)\(more)）"
    }

    // MARK: Results

    /// What one run did with the photos it looked at.
    public struct Tally: Sendable, Equatable {
        public var kept = 0
        public var skipped: [SkipReason: Int] = [:]

        public init(kept: Int = 0, skipped: [SkipReason: Int] = [:]) {
            self.kept = kept
            self.skipped = skipped
        }

        public var skippedTotal: Int { skipped.values.reduce(0, +) }

        /// "本次识别 12 张，跳过 5 张（重复 3 · 多人 1 · 截图 1）"
        public var summary: String {
            let head = "本次识别 \(kept) 张"
            guard skippedTotal > 0 else { return head }
            let parts = SkipReason.allCases.compactMap { reason in
                skipped[reason].flatMap { $0 > 0 ? "\(reason.label) \($0)" : nil }
            }
            return "\(head)，跳过 \(skippedTotal) 张（\(parts.joined(separator: " · "))）"
        }
    }

    /// Kept on the device per signed-in account: which album, which photos were
    /// already looked at, and why the last run skipped what it skipped.
    public struct Ledger: Codable, Sendable, Equatable {
        public var albumID: String?
        public var albumTitle: String?
        public var processed: Set<String> = []
        /// Skipped photos the user brought back: next run takes them without screening.
        public var reinclude: Set<String> = []
        /// Last run's skips, so the user can bring some back.
        public var lastSkipped: [String: SkipReason] = [:]
        /// Photos last run sent for recognition.
        public var lastKept = 0
        /// The batch waiting for review, so closing the sheet loses nothing.
        public var pendingBatchID: String?

        public init() {}

        public mutating func startRun() {
            lastSkipped = [:]
            lastKept = 0
        }

        /// Last run's numbers, still true after the sheet was closed and reopened.
        public var lastTally: Tally {
            Tally(kept: lastKept, skipped: lastSkipped.values.reduce(into: [:]) { $0[$1, default: 0] += 1 })
        }

        public mutating func skip(_ id: String, _ reason: SkipReason) {
            processed.insert(id)
            reinclude.remove(id)
            lastSkipped[id] = reason
        }

        public mutating func done(_ id: String) {
            processed.insert(id)
            reinclude.remove(id)
            lastKept += 1
        }

        /// Last run's skips for `reason` that have not been brought back yet.
        public func skipped(_ reason: SkipReason) -> [String] {
            lastSkipped.filter { $0.value == reason && processed.contains($0.key) }.map(\.key).sorted()
        }

        /// Hands the photos skipped for `reason` back to the next run.
        public mutating func bringBack(_ reason: SkipReason) {
            guard reason.canReinclude else { return }
            for id in skipped(reason) {
                processed.remove(id)
                reinclude.insert(id)
            }
        }
    }

    // MARK: Review defaults

    public enum Choice: String, Sendable, CaseIterable {
        case create, link, skip
    }

    /// New pieces are added, sure matches are linked; an uncertain look-alike is
    /// left for the user to decide, since the closest match is often not it.
    public static func defaultChoice(kind: String, hasExistingItem: Bool) -> Choice {
        switch kind {
        case "new": .create
        case "existing": hasExistingItem ? .link : .create
        default: .skip
        }
    }
}
