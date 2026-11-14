import AidrobeKit
import PhotosUI
import SwiftUI

/// "Before you buy, ask the wardrobe": show a picture of the piece you are
/// considering and get the wardrobe's view of it — what you already own that
/// does the same job, what it would go with, and how sure that reading is.
/// The verdict wording is the server's; this page only lays it out.
struct ShouldIBuyView: View {
    @Environment(AppModel.self) private var app
    @State private var model: ShouldIBuyModel?
    @State private var picked: PhotosPickerItem?

    var body: some View {
        // ZStack, not Group: the task that creates the model must attach to something.
        ZStack {
            if let model {
                switch model.phase {
                case .idle:
                    landing(model)
                case let .working(status):
                    progress(status, model: model)
                case let .stillWorking(candidateID):
                    notice(
                        title: "还在看这张图",
                        message: "比平时慢一些。可以稍等一下再看结果。",
                        action: "再看看"
                    ) { Task { await model.resume(candidateID: candidateID) } }
                case let .decided(decision):
                    DecisionPage(decision: decision, model: model)
                case .unavailable:
                    notice(title: "暂时用不了", message: "这个功能现在没有开放，晚些时候再来。", action: nil) {}
                case let .failed(message):
                    notice(title: "这次没问成", message: message, action: "重新开始") { model.startOver() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .navigationTitle("该不该买")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = ShouldIBuyModel(api: app.api) }
            if app.wardrobe.items.isEmpty { await app.wardrobe.load() }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    return
                }
                await model?.ask(about: image)
            }
        }
    }

    // MARK: Landing

    private func landing(_ model: ShouldIBuyModel) -> some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Text("购买参考").kicker()
                    Text("买之前，先问问衣橱")
                        .font(.display(30, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    Text("给一张商品图或截图，看看衣橱里有没有能替它的，它又能和什么搭。结论只是参考，买不买你说了算。")
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                }
                VStack(alignment: .leading, spacing: Spacing.control) {
                    SectionHeading(title: "最拿不准的是")
                    FlowLayout {
                        ForEach(ShoppingCopy.concerns, id: \.value) { option in
                            Chip(title: option.title, isSelected: model.concern == option.value) {
                                model.concern = model.concern == option.value ? .none : option.value
                            }
                        }
                    }
                }
                PhotosPicker(selection: $picked, matching: .images) {
                    Text("选一张图").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                if !model.history.isEmpty {
                    asked(model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
    }

    private func asked(_ model: ShouldIBuyModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "问过的")
                .padding(.bottom, 4)
            ForEach(model.history) { entry in
                Button {
                    Task { await model.replay(entry) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                        Text(entry.askedAt.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))
                            .font(.subheadline)
                            .foregroundStyle(Color.tertiaryLabel)
                            .frame(width: 64, alignment: .leading)
                        Text(entry.text)
                            .font(.body)
                            .foregroundStyle(Color.label)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: Spacing.tight)
                        if let call = entry.call {
                            Text(call.title)
                                .font(.subheadline)
                                .foregroundStyle(Color.accent)
                        }
                    }
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("从这里移除", systemImage: "trash", role: .destructive) { model.forget(entry) }
                }
                Divider().overlay(Color.separator)
            }
        }
    }

    // MARK: States

    private func progress(_ status: String, model: ShouldIBuyModel) -> some View {
        VStack(spacing: Spacing.section) {
            if let photo = model.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(.rect(cornerRadius: Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.separator))
            }
            ProgressView(status)
        }
        .padding(Spacing.screen)
    }

    private func notice(title: String, message: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            Text(title)
                .font(.display(28, weight: .black, relativeTo: .title))
                .foregroundStyle(Color.label)
            Text(message)
                .font(.body)
                .foregroundStyle(Color.secondaryLabel)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .padding(.top, Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.screen)
    }
}

/// The decision, laid out as evidence first: what the wardrobe says, why, what
/// it was compared with, how sure it is — then the user's own call.
private struct DecisionPage: View {
    let decision: Wire.WardrobeDecisionResponse
    let model: ShouldIBuyModel
    @Environment(AppModel.self) private var app

    private var similar: [Wire.ComparisonItemModel] { decision.closetComparison.similarItems ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                verdict
                reasons
                comparison
                confidence
                yourCall
                Button("再问一件") { model.startOver() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
    }

    private var verdict: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            if let photo = model.photo {
                HStack(alignment: .bottom, spacing: Spacing.row) {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 120)
                        .clipShape(.rect(cornerRadius: Radius.tile))
                        .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.separator))
                    if let seen = ShoppingCopy.seen(model.parsed) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("看到的是").kicker()
                            Text(seen)
                                .font(.subheadline)
                                .foregroundStyle(Color.secondaryLabel)
                        }
                    }
                }
            }
            Text("衣橱的看法").kicker()
            Text(decision.decisionText)
                .font(.display(26, weight: .black, relativeTo: .title))
                .foregroundStyle(Color.label)
        }
    }

    @ViewBuilder private var reasons: some View {
        if !decision.reasons.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.control) {
                SectionHeading(title: "依据")
                ForEach(Array(decision.reasons.enumerated()), id: \.offset) { index, reason in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.control) {
                        Text("0\(index + 1)")
                            .font(.display(15, weight: .regular, relativeTo: .subheadline))
                            .foregroundStyle(Color.accent)
                        Text(reason.text)
                            .font(.body)
                            .foregroundStyle(Color.secondaryLabel)
                    }
                }
            }
        }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            SectionHeading(title: "和衣橱对照")
            Text(decision.closetComparison.summaryText)
                .font(.body)
                .foregroundStyle(Color.secondaryLabel)
            ForEach(Wire.ComparisonItemModel.RelationPayload.allCases, id: \.self) { relation in
                let pieces = similar.filter { $0.relation == relation }
                if !pieces.isEmpty {
                    Text(relation == .covers ? "已经能替它的" : "能和它搭的")
                        .font(.subheadline)
                        .foregroundStyle(Color.tertiaryLabel)
                        .padding(.top, Spacing.tight)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: Spacing.control) {
                            ForEach(pieces, id: \.itemId) { piece in
                                NavigationLink {
                                    ItemDetailView(itemID: piece.itemId)
                                } label: {
                                    ownedPiece(piece)
                                }
                                .buttonStyle(.plain)
                                // A piece removed since the decision has no page to open.
                                .disabled(app.wardrobe.item(piece.itemId) == nil)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    // Bleed to the screen edges so the row scrolls under the margin.
                    .contentMargins(.horizontal, Spacing.screen, for: .scrollContent)
                    .padding(.horizontal, -Spacing.screen)
                }
            }
        }
    }

    private func ownedPiece(_ piece: Wire.ComparisonItemModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GarmentImage(url: app.wardrobe.imageURL(piece.itemId) ?? piece.imageUrl.flatMap(URL.init(string:)))
                .frame(width: 104, height: 130)
                .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.tile))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.separator))
            if let name = app.wardrobe.item(piece.itemId)?.displayName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(width: 104, alignment: .leading)
            }
        }
    }

    private var confidence: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            VStack(spacing: 0) {
                Divider().overlay(Color.separator)
                FactRow(title: "这个判断") { Text(ShoppingCopy.uncertainty(decision.uncertainty)) }
            }
            Text(decision.boundaryNote)
                .font(.footnote)
                .foregroundStyle(Color.tertiaryLabel)
        }
    }

    private var yourCall: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            SectionHeading(title: "你的决定")
            FlowLayout {
                ForEach(AskedPurchase.Call.allCases, id: \.self) { call in
                    Chip(title: call.title, isSelected: model.call(for: decision.id) == call) {
                        model.setCall(model.call(for: decision.id) == call ? nil : call, for: decision.id)
                    }
                }
            }
            Text("只记在这台手机上，方便你回头看。")
                .font(.footnote)
                .foregroundStyle(Color.tertiaryLabel)
        }
        .sensoryFeedback(.selection, trigger: model.call(for: decision.id))
    }
}

/// Display copy for the purchase-decision vocabulary.
enum ShoppingCopy {
    static let concerns: [(value: Wire.DecisionRequest.ConcernPayload, title: String)] = [
        (.redundancy, "会不会和已有的重复"),
        (.color, "颜色好不好搭"),
        (.scene, "有没有场合穿"),
        (.volume, "版型和宽松度"),
    ]

    static func uncertainty(_ level: Wire.WardrobeDecisionResponse.UncertaintyPayload) -> String {
        switch level {
        case .low: "比较有把握"
        case .medium: "有一定把握"
        case .high: "把握不大，仅供参考"
        }
    }

    /// What recognition made of the picture, e.g. "白色 · 上装"; nil when it saw nothing usable.
    static func seen(_ item: Wire.ParsedItemModel?) -> String? {
        guard let item else { return nil }
        var parts = (item.colors ?? []).prefix(2).map(Garment.color)
        if let category = item.category { parts.append(Garment.category(category)) }
        if let price = item.price, !price.isEmpty { parts.append(price) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
