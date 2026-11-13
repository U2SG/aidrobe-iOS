import Foundation

/// Lays an outfit out as a two-column flat-lay: each garment gets a frame in the
/// unit square, tall pieces get more height, and both columns end flush.
public enum OutfitBoardLayout {
    public struct Frame: Sendable, Equatable {
        public var x, y, width, height: Double
    }

    /// Relative height a garment wants, by `display_role` / category.
    static func weight(for role: String) -> Double {
        switch role {
        case "dress": 1.7
        case "bottom": 1.35
        case "outer", "outerwear": 1.25
        case "top": 1.0
        case "shoes": 0.7
        default: 0.6
        }
    }

    /// Frames in input order. `roles` are ordered as the outfit lists them
    /// (upper body first), which keeps tops on the left and shoes low.
    public static func frames(for roles: [String], leftShare: Double = 0.54) -> [Frame] {
        guard roles.count > 1 else {
            return roles.map { _ in Frame(x: 0, y: 0, width: 1, height: 1) }
        }
        var columns: [[(index: Int, weight: Double)]] = [[], []]
        var totals = [0.0, 0.0]
        // Heaviest first so the two columns balance; ties keep outfit order.
        let order = roles.indices.sorted {
            let (a, b) = (weight(for: roles[$0]), weight(for: roles[$1]))
            return a == b ? $0 < $1 : a > b
        }
        for index in order {
            let column = totals[0] <= totals[1] ? 0 : 1
            columns[column].append((index, weight(for: roles[index])))
            totals[column] += weight(for: roles[index])
        }
        // The column holding the first (upper-body) piece reads first, so it goes left.
        if columns[1].contains(where: { $0.index == 0 }) {
            columns.swapAt(0, 1)
            totals.swapAt(0, 1)
        }
        var frames = [Frame](repeating: Frame(x: 0, y: 0, width: 0, height: 0), count: roles.count)
        for (column, entries) in columns.enumerated() {
            var y = 0.0
            for entry in entries.sorted(by: { $0.index < $1.index }) {
                let height = entry.weight / totals[column]
                frames[entry.index] = Frame(
                    x: column == 0 ? 0 : leftShare,
                    y: y,
                    width: column == 0 ? leftShare : 1 - leftShare,
                    height: height
                )
                y += height
            }
        }
        return frames
    }
}
