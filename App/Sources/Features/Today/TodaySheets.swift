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
    @State private var errorMessage: String?

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
            Picker("感受", selection: Binding(get: { kind }, set: { value in
                guard kind != value else { return }
                kind = value
                selected.removeAll()
            })) {
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
                Text(selected.isEmpty ? "可选原因，帮助调整下一次搭配。" : "已选 \(selected.count) 项原因")
                    .font(.footnote)
                    .foregroundStyle(Color.tertiaryLabel)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(Color.danger)
            }
            Spacer(minLength: 0)
            Button {
                let submission = (kind, selected.sorted())
                isSending = true
                errorMessage = nil
                Task {
                    if await model.sendFeedback(submission.0, tags: submission.1, for: outfit) {
                        dismiss()
                    } else {
                        errorMessage = model.notice ?? "没能保存反馈，请重试。"
                    }
                    isSending = false
                }
            } label: {
                Text(isSending ? "正在记下…" : "记下").frame(maxWidth: .infinity)
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
        .disabled(isSending)
        .interactiveDismissDisabled(isSending)
    }
}

/// A one-time request that applies to the next recommendation.
struct ContextSheet: View {
    let model: TodayModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingRequest: Bool
    @State private var chip: ContextChip?
    @State private var request = ""
    @State private var errorMessage: String?

    private static let compact = PresentationDetent.height(410)
    @State private var detent = Self.compact

    private var cleaned: String { request.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { cleaned.unicodeScalars.count > Endpoints.todayContextTextLimit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.row) {
                HStack(alignment: .top, spacing: Spacing.tight) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("今天有什么不一样？")
                            .font(.display(26, relativeTo: .title))
                            .foregroundStyle(Color.label)
                            .accessibilityAddTraits(.isHeader)
                        Text("只影响今天这一次，不会记成你的长期偏好。")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.elevatedBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                FlowLayout {
                    ForEach(ContextChip.all) { option in
                        Chip(title: option.title, isSelected: chip == option && cleaned.isEmpty) {
                            request = ""
                            chip = chip == option ? nil : option
                            editingRequest = false
                            errorMessage = nil
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("也可以自己说")
                        .font(.subheadline.weight(.semibold))
                    TextField("例如：下午有会，想穿得正式一点", text: $request, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($editingRequest)
                        .accessibilityLabel("今天的穿搭要求")
                        .padding(Spacing.control)
                        .background(Color.elevatedBackground, in: RoundedRectangle(cornerRadius: Radius.tile))
                        .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.separator))
                        .onChange(of: request) {
                            if !cleaned.isEmpty { chip = nil }
                            errorMessage = nil
                        }
                    if tooLong {
                        Text("最多输入 200 个字符。").font(.footnote).foregroundStyle(Color.danger)
                    } else if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(Color.danger)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button {
                let choice = cleaned.isEmpty ? chip : nil
                let text = cleaned.isEmpty ? nil : cleaned
                errorMessage = nil
                editingRequest = false
                Task {
                    do {
                        try await model.refresh(chip: choice, text: text)
                        if (choice != nil || text != nil) && model.appliedChip == nil && model.appliedText == nil {
                            errorMessage = "当前服务未启用临时穿搭要求。"
                        } else {
                            dismiss()
                        }
                    } catch {
                        errorMessage = TodayModel.refreshMessage(error)
                    }
                }
            } label: {
                Text(model.isRefreshing ? "正在重新搭…" : (chip == nil && cleaned.isEmpty ? "重新搭一套" : "按这个重新搭"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(tooLong)
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.tight)
            .background(Color.background)
        }
        .disabled(model.isRefreshing)
        .interactiveDismissDisabled(model.isRefreshing)
        .presentationDetents([Self.compact, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.background)
        .onChange(of: editingRequest) { _, focused in
            detent = focused ? .large : Self.compact
        }
        .onAppear {
            chip = model.appliedChip
            request = model.appliedText ?? ""
        }
    }
}
