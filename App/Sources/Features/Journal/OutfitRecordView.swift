import AidrobeKit
import SwiftUI

/// One day in the journal: what was worn, the pieces, and how it felt.
struct OutfitRecordView: View {
    let entry: Wire.OutfitHistoryEntry
    let model: JournalModel
    @State private var shareDraft: OutfitShareDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dateLine).kicker()
                    Text(entry.outfit?.title ?? "自己搭的一套")
                        .font(.display(34, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    if let reason = entry.outfit?.reasonText, !reason.isEmpty {
                        Text(reason)
                            .font(.body)
                            .foregroundStyle(Color.secondaryLabel)
                    }
                }
                let items = model.boardItems(for: entry)
                if !items.isEmpty {
                    OutfitBoard(items: items)
                    pieces(items)
                }
                if let photo = entry.ootdImageUrl.flatMap(URL.init(string:)) {
                    VStack(alignment: .leading, spacing: Spacing.control) {
                        SectionHeading(title: "那天的照片")
                        AsyncImage(url: photo) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.fill.aspectRatio(0.8, contentMode: .fit)
                        }
                        .clipShape(.rect(cornerRadius: Radius.tile))
                    }
                }
                feeling
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            let items = model.boardItems(for: entry)
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("分享这套", systemImage: "square.and.arrow.up") {
                        shareDraft = OutfitShareDraft(items: items, date: Garment.day(entry.wornDate))
                    }
                }
            }
        }
        .sheet(item: $shareDraft) { draft in
            OutfitShareSheet(draft: draft)
        }
    }

    private var dateLine: String {
        guard let parts = JournalDay.parts(entry.wornDate) else { return entry.wornDate }
        return "\(parts.year)年\(parts.month)月\(parts.day)日 \(JournalDay.weekday(entry.wornDate))"
    }

    private func pieces(_ items: [BoardItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "这一套")
                .padding(.bottom, 4)
            ForEach(items) { item in
                let row = HStack(spacing: Spacing.row) {
                    Text(Garment.category(item.role))
                        .font(.subheadline)
                        .foregroundStyle(Color.tertiaryLabel)
                        .frame(width: 52, alignment: .leading)
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(model.isInWardrobe(item) ? Color.label : Color.tertiaryLabel)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.tight)
                    if model.isInWardrobe(item) {
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(Color.tertiaryLabel)
                    }
                }
                .frame(minHeight: 48)
                .contentShape(.rect)
                if model.isInWardrobe(item) {
                    NavigationLink {
                        ItemDetailView(itemID: item.itemID)
                    } label: {
                        row
                    }
                    .buttonStyle(.plain)
                } else {
                    row
                }
                Divider().overlay(Color.separator)
            }
        }
    }

    private var feeling: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            SectionHeading(title: "那天的感受")
            if let kind = JournalModel.feeling(entry.feedbackType) {
                Text(kind)
                    .font(.display(22, relativeTo: .title2))
                    .foregroundStyle(Color.label)
                let reasons = model.reasons(entry)
                if !reasons.isEmpty {
                    Text(reasons.joined(separator: " · "))
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                }
            } else {
                Text("那天没有留下感受。")
                    .font(.body)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }
}
