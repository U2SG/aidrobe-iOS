import AidrobeKit
import SwiftUI

/// Swap one garment for another of the same kind from the wardrobe.
struct SwapSheet: View {
    let outfit: Wire.OutfitResponse
    let slot: BoardItem
    let model: TodayModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Wire.ReplacementCandidateResponse]?
    @State private var failure: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.control), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.row) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("换一件\(Garment.category(slot.role))")
                        .font(.display(26, relativeTo: .title))
                        .foregroundStyle(Color.label)
                    Text("现在是「\(slot.name)」")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if slot.isSwapped {
                    Button("换回推荐的那件") {
                        model.swap(slot, to: nil, in: outfit)
                        dismiss()
                    }
                    .buttonStyle(.glass)
                }
                if let candidates {
                    if candidates.isEmpty {
                        Text("衣橱里暂时没有能替换的\(Garment.category(slot.role))。")
                            .font(.body)
                            .foregroundStyle(Color.secondaryLabel)
                            .padding(.top, Spacing.tight)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.row) {
                            ForEach(candidates, id: \.itemId) { candidate in
                                Button {
                                    model.swap(slot, to: candidate.itemId, in: outfit)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        GarmentImage(url: app.wardrobe.imageURL(candidate.itemId))
                                            .aspectRatio(0.8, contentMode: .fit)
                                        Text(app.wardrobe.item(candidate.itemId)?.displayName ?? candidate.title)
                                            .font(.caption)
                                            .foregroundStyle(Color.secondaryLabel)
                                            .lineLimit(2, reservesSpace: true)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else if let failure {
                    Text(failure)
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
            .padding(.top, Spacing.tight)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.background)
        .task {
            do {
                candidates = try await model.replacements(for: slot, in: outfit)
            } catch {
                failure = userMessage(for: error)
            }
        }
    }
}

/// How the outfit worked out. Tags come from the backend, so every one of
/// them is something the next recommendation can act on.
struct FeedbackSheet: View {
    let outfit: Wire.OutfitResponse
    let model: TodayModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: FeedbackKind
    @State private var selected: Set<String> = []
    @State private var isSending = false

    private static let positiveKeys: Set<String> = ["complimented", "comfortable", "confident"]

    init(outfit: Wire.OutfitResponse, model: TodayModel) {
        self.outfit = outfit
        self.model = model
        // Opened before wearing means "not this one"; after wearing, start neutral-positive.
        _kind = State(initialValue: model.wornOutfitIDs.contains(outfit.outfitId) ? .like : .dislike)
    }

    private var tags: [Wire.FeedbackTagResponse] {
        model.feedbackTags.filter {
            $0.appliesTo.contains(.overall) && Self.positiveKeys.contains($0.key) == (kind == .like)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("这套怎么样？")
                .font(.display(26, relativeTo: .title))
                .foregroundStyle(Color.label)
            Picker("感受", selection: $kind) {
                Text("挺好").tag(FeedbackKind.like)
                Text("不太合适").tag(FeedbackKind.dislike)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: Spacing.control) {
                FlowLayout {
                    ForEach(tags, id: \.key) { tag in
                        Chip(title: tag.labelZhCn, isSelected: selected.contains(tag.key)) {
                            selected.formSymmetricDifference([tag.key])
                        }
                    }
                }
                Text("选中的原因会直接影响之后的搭配。")
                    .font(.footnote)
                    .foregroundStyle(Color.tertiaryLabel)
            }
            Spacer(minLength: 0)
            Button {
                isSending = true
                Task {
                    if await model.sendFeedback(kind, tags: Array(selected), for: outfit) { dismiss() }
                    isSending = false
                }
            } label: {
                Text("记下").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isSending)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.screen)
        .padding(.top, Spacing.row)
        .presentationDetents([.medium])
        .presentationBackground(Color.background)
        .onChange(of: kind) { selected = [] }
    }
}

/// Tell Today what is different about the day, then get a set that fits.
struct ContextSheet: View {
    let model: TodayModel
    @Environment(\.dismiss) private var dismiss
    @State private var chip: ContextChip?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: 6) {
                Text("今天有什么不一样？")
                    .font(.display(26, relativeTo: .title))
                    .foregroundStyle(Color.label)
                Text("只影响今天这一次，不会记成你的长期偏好。")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }
            FlowLayout {
                ForEach(ContextChip.all) { option in
                    Chip(title: option.title, isSelected: chip == option) {
                        chip = chip == option ? nil : option
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                Task {
                    await model.refresh(chip: chip)
                    dismiss()
                }
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView()
                    } else {
                        Text(chip == nil ? "重新搭一套" : "按这个重新搭")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.isRefreshing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.screen)
        .padding(.top, Spacing.row)
        .presentationDetents([.medium])
        .presentationBackground(Color.background)
        .onAppear { chip = model.appliedChip }
    }
}
