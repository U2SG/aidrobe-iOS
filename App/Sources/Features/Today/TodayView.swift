import AidrobeKit
import SwiftUI

/// Today V2: one outfit at a time from the user's real wardrobe, with
/// "wear this", "another one" and structured feedback.
struct TodayView: View {
    @Environment(AppModel.self) private var app
    @State private var model: TodayModel?
    @State private var index = 0
    @State private var feedbackOutfit: Wire.OutfitResponse?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .navigationTitle("今日")
        .task {
            if model == nil { model = TodayModel(api: app.api) }
            await model?.load()
        }
    }

    @ViewBuilder
    private func content(_ model: TodayModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("正在为你搭配…")
        case let .failed(message):
            ContentUnavailableView {
                Label("没能拿到今日推荐", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await model.load() } }
                    .buttonStyle(.glass)
            }
        case .loaded:
            if model.isReady {
                ready(model)
            } else {
                ContentUnavailableView {
                    Label("还搭不出一套", systemImage: "hanger")
                } description: {
                    Text(model.today?.guidanceText ?? "先导入几件常穿的上衣和下装")
                }
                .refreshable { await model.load() }
            }
        }
    }

    private func ready(_ model: TodayModel) -> some View {
        let outfits = model.outfits
        let outfit = outfits[min(index, outfits.count - 1)]
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                if let weather = model.today?.context?.weather {
                    Label(
                        "\(weather.condition) · \(Int(weather.temperatureC.rounded()))°C",
                        systemImage: "cloud.sun"
                    )
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                }
                OutfitCard(outfit: outfit, model: model)
                actions(outfit, model: model, count: outfits.count)
            }
            .padding(Spacing.screen)
        }
        .refreshable { await model.load() }
        .sheet(item: $feedbackOutfit) { outfit in
            FeedbackSheet(outfit: outfit, model: model)
                .presentationDetents([.medium])
        }
        .overlay(alignment: .bottom) { NoticeBanner(model: model) }
        .sensoryFeedback(.success, trigger: model.wornOutfitIDs)
    }

    private func actions(_ outfit: Wire.OutfitResponse, model: TodayModel, count: Int) -> some View {
        let worn = model.wornOutfitIDs.contains(outfit.outfitId)
        return VStack(spacing: Spacing.control) {
            Button {
                Task { await model.markWorn(outfit) }
            } label: {
                Label(worn ? "今天就穿这套" : "穿这套", systemImage: worn ? "checkmark" : "tshirt")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(worn)

            HStack(spacing: Spacing.control) {
                if count > 1 {
                    Button {
                        withAnimation { index = (index + 1) % count }
                    } label: {
                        Label("换一套", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                Menu {
                    Button("喜欢", systemImage: "heart") {
                        Task { await model.sendFeedback(.like, reasons: [], for: outfit) }
                    }
                    Button("不太合适…", systemImage: "hand.thumbsdown") {
                        feedbackOutfit = outfit
                    }
                } label: {
                    Label(feedbackLabel(model.feedbackByOutfit[outfit.outfitId]), systemImage: "bubble.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
    }

    private func feedbackLabel(_ kind: FeedbackKind?) -> String {
        switch kind {
        case .love, .like: "已标记喜欢"
        case .dislike: "已反馈"
        default: "反馈"
        }
    }
}

extension Wire.OutfitResponse: @retroactive Identifiable {
    public var id: String { outfitId }
}

private struct OutfitCard: View {
    let outfit: Wire.OutfitResponse
    let model: TodayModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            VStack(alignment: .leading, spacing: 4) {
                Text(outfit.title)
                    .font(.title2.bold())
                    .foregroundStyle(Color.label)
                Text(outfit.reason)
                    .font(.callout)
                    .foregroundStyle(Color.secondaryLabel)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.control) {
                ForEach(outfit.items, id: \.itemId) { item in
                    ItemTile(url: model.imageURL(for: item), name: model.displayName(for: item))
                }
            }
            if let reasoning = outfit.reasoning, !reasoning.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(reasoning.prefix(3).enumerated()), id: \.offset) { _, reason in
                        Label(reason.text, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(Color.secondaryLabel)
                    }
                }
            }
        }
        .padding(Spacing.row)
        .background(Color.elevatedBackground, in: .rect(cornerRadius: 20))
    }
}

private struct ItemTile: View {
    let url: URL?
    let name: String

    var body: some View {
        VStack(spacing: 6) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit()
                default:
                    Image(systemName: "tshirt")
                        .font(.largeTitle)
                        .foregroundStyle(Color.tertiaryLabel)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 140)
            .background(Color.fill, in: .rect(cornerRadius: 12))
            Text(name)
                .font(.caption)
                .foregroundStyle(Color.secondaryLabel)
                .lineLimit(1)
        }
    }
}

private struct FeedbackSheet: View {
    let outfit: Wire.OutfitResponse
    let model: TodayModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<FeedbackReason> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("哪里不合适？") {
                    ForEach(FeedbackReason.allCases) { reason in
                        Toggle(reason.label, isOn: binding(for: reason))
                    }
                }
            }
            .navigationTitle("反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") {
                        Task {
                            await model.sendFeedback(.dislike, reasons: Array(selected), for: outfit)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func binding(for reason: FeedbackReason) -> Binding<Bool> {
        Binding(
            get: { selected.contains(reason) },
            set: { isOn in
                if isOn { selected.insert(reason) } else { selected.remove(reason) }
            }
        )
    }
}

private struct NoticeBanner: View {
    let model: TodayModel

    var body: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.callout)
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, 10)
                .glassEffect()
                .padding(.bottom, Spacing.section)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(2.5))
                    model.notice = nil
                }
        }
    }
}

extension FeedbackReason {
    var label: String {
        switch self {
        case .tooWarm: "太热了"
        case .tooCold: "太冷了"
        case .tooFormal: "太正式"
        case .tooCasual: "太随意"
        case .wrongFit: "不合身"
        case .notMyStyle: "不是我的风格"
        }
    }
}
