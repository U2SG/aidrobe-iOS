import AidrobeKit
import SwiftUI

/// One trip: the garments to bring, grouped by kind and tickable as packed,
/// then how they are worn day by day and what the wardrobe can't cover.
struct PackingListDetailView: View {
    let listID: String
    let model: PackingModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            if let list = model.list(listID) {
                page(list)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .toast(Binding(get: { model.notice }, set: { model.notice = $0 }))
    }

    private func page(_ list: Wire.PackingListResponse) -> some View {
        let pieces = list.pieces
        let packed = pieces.count { $0.isPacked }
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("出行打包").kicker()
                    Text(PackingCopy.title(list))
                        .font(.display(34, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    Text(PackingCopy.summary(list))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if pieces.isEmpty {
                    Text("衣橱里的衣服还不够排出这趟行程。先放进几件上装、下装和鞋，再排一次。")
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                } else {
                    bring(pieces, packed: packed, list: list)
                    days(list)
                }
                missing(list)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .sensoryFeedback(.success, trigger: packed == pieces.count && !pieces.isEmpty)
    }

    // MARK: What to bring

    private func bring(_ pieces: [PackingPiece], packed: Int, list: Wire.PackingListResponse) -> some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            VStack(alignment: .leading, spacing: Spacing.control) {
                SectionHeading(title: "要带的")
                Text(packed == pieces.count ? "\(pieces.count) 件，都装好了" : "\(pieces.count) 件，已装 \(packed) 件")
                    .font(.body)
                    .foregroundStyle(Color.secondaryLabel)
            }
            // Wardrobe order; anything of an unknown kind goes last.
            ForEach(Garment.categories + ["other"], id: \.self) { kind in
                let group = pieces.filter { self.kind(of: $0.itemID) == kind }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind == "other" ? "其他" : Garment.category(kind))
                            .font(.subheadline)
                            .foregroundStyle(Color.tertiaryLabel)
                            .padding(.bottom, Spacing.tight)
                        ForEach(group) { piece in
                            pieceRow(piece, totalDays: list.days)
                            Divider().overlay(Color.separator)
                        }
                    }
                }
            }
        }
    }

    private func kind(of itemID: String) -> String {
        guard let category = app.wardrobe.item(itemID)?.category, Garment.categories.contains(category) else {
            return "other"
        }
        return category
    }

    private func pieceRow(_ piece: PackingPiece, totalDays: Int?) -> some View {
        Button {
            Task { await model.setPacked(!piece.isPacked, itemID: piece.itemID, in: listID) }
        } label: {
            HStack(spacing: Spacing.row) {
                Image(systemName: piece.isPacked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(piece.isPacked ? Color.accent : Color.tertiaryLabel)
                GarmentImage(url: app.wardrobe.imageURL(piece.itemID))
                    .frame(width: 48, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.wardrobe.item(piece.itemID)?.displayName ?? "已不在衣橱里的一件")
                        .font(.body)
                        .foregroundStyle(piece.isPacked ? Color.tertiaryLabel : Color.label)
                        .strikethrough(piece.isPacked, color: Color.tertiaryLabel)
                        .lineLimit(1)
                    Text(wornOn(piece.days, totalDays: totalDays))
                        .font(.caption)
                        .foregroundStyle(Color.tertiaryLabel)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 72)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: piece.isPacked)
        .accessibilityAddTraits(piece.isPacked ? .isSelected : [])
    }

    private func wornOn(_ days: [Int], totalDays: Int?) -> String {
        if let totalDays, totalDays > 1, days.count == totalDays { return "每天都穿" }
        return "第 \(days.map(String.init).joined(separator: "、")) 天穿"
    }

    // MARK: Day by day

    @ViewBuilder private func days(_ list: Wire.PackingListResponse) -> some View {
        let byDay = Dictionary(grouping: list.items, by: \.day)
        VStack(alignment: .leading, spacing: Spacing.row) {
            SectionHeading(title: "每天怎么穿")
            ForEach(byDay.keys.sorted(), id: \.self) { day in
                let rows = byDay[day] ?? []
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                        Text("第 \(day) 天")
                            .font(.display(17, relativeTo: .headline))
                            .foregroundStyle(Color.label)
                        if let scene = rows.first?.scene {
                            Text(PackingCopy.scene(scene))
                                .font(.subheadline)
                                .foregroundStyle(Color.tertiaryLabel)
                        }
                    }
                    HStack(spacing: Spacing.tight) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GarmentImage(url: app.wardrobe.imageURL(row.itemId))
                                .frame(width: 64, height: 80)
                                .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.tile))
                                .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.separator))
                        }
                    }
                }
            }
        }
    }

    // MARK: Gaps

    /// Kinds the wardrobe has nothing wearable for. The server's reason text is
    /// not localised, so only the kind is shown.
    @ViewBuilder private func missing(_ list: Wire.PackingListResponse) -> some View {
        let kinds = (list.plan?.missingItems ?? []).map(\.category).reduce(into: [String]()) { unique, kind in
            if !unique.contains(kind) { unique.append(kind) }
        }
        if !kinds.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.control) {
                SectionHeading(title: "衣橱里还缺")
                Text(kinds.map(Garment.category).joined(separator: "、"))
                    .font(.body)
                    .foregroundStyle(Color.label)
                Text("这趟有场合用得上，但衣橱里没有能穿的。不一定要买，换个搭法也行。")
                    .font(.footnote)
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
    }
}
