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
    private let source: ShoppingDesignSource?
    private let decisionID: String?
    private let onDecision: (Wire.WardrobeDecisionResponse) -> Void
    private let onContinue: ((String) -> Void)?

    init(
        source: ShoppingDesignSource? = nil, decisionID: String? = nil,
        onDecision: @escaping (Wire.WardrobeDecisionResponse) -> Void = { _ in },
        onContinue: ((String) -> Void)? = nil
    ) {
        self.source = source
        self.decisionID = decisionID
        self.onDecision = onDecision
        self.onContinue = onContinue
    }

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
                case .reviewingLatest:
                    reviewLatest(model)
                case let .decided(decision):
                    DecisionPage(decision: decision, model: model) { conversationID in
                        if let onContinue { onContinue(conversationID) }
                        else { app.discussConversation(conversationID) }
                    }
                case .unavailable:
                    if model.canRetry {
                        failed("这个功能暂时用不了。这次的内容已保留，稍后可以直接重试。", model: model)
                    } else {
                        notice(title: "暂时用不了", message: "这个功能现在没有开放，晚些时候再来。", action: nil) {}
                    }
                case let .failed(message):
                    failed(message, model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .navigationTitle("该不该买")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            let generation = AccountLocalData.generation
            if app.wardrobe.items.isEmpty { await app.wardrobe.load() }
            guard model == nil, !Task.isCancelled, generation == AccountLocalData.generation else { return }
            let created = ShouldIBuyModel(api: app.api, source: source, onDecision: onDecision)
            model = created
            if let decisionID { await created.replay(decisionID: decisionID) }
            else {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-AidrobeShoppingDemo") {
                    await created.ask(about: ImportDemoModifier.samplePhoto())
                }
                #endif
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Text("购买参考").kicker()
                    Text(model.source == nil ? "买之前，先问问衣橱" : "这件适合这次的想法吗？")
                        .font(.display(30, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    Text(model.source == nil
                         ? "给一张衣物照片或截图，看看衣橱里有没有能替它的，它又能和什么搭。结论只是参考，买不买你说了算。"
                         : "给一张想买的衣服照片或截图，结合这次的想法和已有衣橱来看。看完还可以回到原来的对话接着聊。")
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if let source = model.source {
                    ShoppingDesignSummary(constraints: source.constraints, title: "带着这些条件看")
                }
                concerns(model)
                PhotosPicker(selection: $picked, matching: .images) {
                    Text("选一张图").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityIdentifier("shopping.pickPhoto")
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
                        if entry.choiceSynced == true, let call = entry.call {
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
                    Button("从本机列表移除", systemImage: "trash", role: .destructive) { model.forget(entry) }
                }
                Divider().overlay(Color.separator)
            }
        }
    }

    // MARK: States

    private func concerns(_ model: ShouldIBuyModel) -> some View {
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
    }

    private func failed(_ message: String, model: ShouldIBuyModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                Text("这次没问成").font(.display(28, weight: .black, relativeTo: .title))
                Text(message).foregroundStyle(Color.secondaryLabel)
                retainedCandidate(model)
                if model.canRetry {
                    Button(model.needsLatestDesign ? "读取最新条件" : "重试这次判断") {
                        Task { await model.retry() }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier(model.needsLatestDesign ? "shopping.refreshDesign" : "shopping.retry")
                }
                Button("换一张图") { model.startOver() }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
    }

    private func reviewLatest(_ model: ShouldIBuyModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                Text("按现在的想法再看看").font(.display(28, weight: .black, relativeTo: .title))
                retainedCandidate(model, showsConcern: false)
                if let source = model.source {
                    ShoppingDesignSummary(constraints: source.constraints, title: "现在想要的是")
                }
                concerns(model)
                Text("还是刚才那件衣服。确认后，会按这些条件重新判断，之前的判断也会保留。")
                    .foregroundStyle(Color.secondaryLabel)
                Button("按这些条件重新看") { Task { await model.evaluateLatest() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("shopping.evaluateLatest")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
    }

    @ViewBuilder private func retainedCandidate(_ model: ShouldIBuyModel, showsConcern: Bool = true) -> some View {
        if let photo = model.photo {
            Image(uiImage: photo)
                .resizable().scaledToFit().frame(maxHeight: 220)
                .clipShape(.rect(cornerRadius: Radius.card))
                .accessibilityLabel("已保留的候选衣服")
        }
        if showsConcern, let concern = ShoppingCopy.concerns.first(where: { $0.value == model.evaluationConcern }) {
            Text("你最拿不准的是：\(concern.title)")
                .font(.subheadline).foregroundStyle(Color.secondaryLabel)
        }
    }

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
    let onContinue: (String) -> Void
    @Environment(AppModel.self) private var app

    private var similar: [Wire.ComparisonItemModel] { decision.closetComparison.similarItems ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                verdict
                if let context = decision.designContext {
                    ShoppingDesignSummary(constraints: context.constraints, title: "当时带来的条件")
                    if let source = model.source, source.conversationID == context.conversationId,
                       source.revision != context.revision {
                        Text("这是按当时的条件留下的判断；对话里已有新的想法。")
                            .font(.footnote).foregroundStyle(Color.tertiaryLabel)
                    }
                }
                reasons
                comparison
                confidence
                yourCall
                if let context = decision.designContext {
                    Button("回到对话接着聊", systemImage: "text.bubble") { onContinue(context.conversationId) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(model.isSavingChoice)
                        .accessibilityIdentifier("shopping.continue")
                    Text("这次的判断已记在原来的对话里，继续聊时不用再说一遍。")
                        .font(.footnote).foregroundStyle(Color.tertiaryLabel)
                    Button("按现在的想法，再看这件", systemImage: "arrow.clockwise") {
                        Task { await model.reassessCurrentDecision() }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(model.isSavingChoice)
                    .accessibilityIdentifier("shopping.reassess")
                }
                Button(model.source == nil ? "再问一件" : "按当前条件再问一件") { model.startOver() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(model.isSavingChoice)
                    .accessibilityIdentifier("shopping.startOver")
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
                .accessibilityIdentifier("shopping.result")
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
            if let context = decision.designContext {
                if let dimensions = context.evaluatedDimensions, !dimensions.isEmpty {
                    Text("这次已核对：\(dimensions.map(ShoppingCopy.evaluatedDimension).joined(separator: "、"))。")
                        .font(.footnote).foregroundStyle(Color.secondaryLabel)
                }
                if let dimensions = context.unverifiedDimensions, !dimensions.isEmpty {
                    SectionHeading(title: "还不能确认的部分")
                    ForEach(Array(Set(dimensions)).sorted(), id: \.self) { dimension in
                        Text(ShoppingCopy.unverifiedDimension(dimension))
                            .font(.footnote).foregroundStyle(Color.secondaryLabel)
                    }
                }
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
                        Task { await model.setCall(model.call(for: decision.id) == call ? nil : call, for: decision.id) }
                    }
                    .disabled(model.isSavingChoice)
                    .accessibilityIdentifier("shopping.choice.\(call.rawValue)")
                }
            }
            if model.isSavingChoice {
                ProgressView("正在记下你的决定…")
            } else if let failure = model.choiceFailure {
                Text(failure).font(.footnote).foregroundStyle(Color.secondaryLabel)
                Button("重新保存选择") { Task { await model.retryChoice() } }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("shopping.choice.retry")
            } else if let call = model.call(for: decision.id) {
                Text("已记下：\(call.title)")
                    .font(.footnote).foregroundStyle(Color.secondaryLabel)
                    .accessibilityIdentifier("shopping.choice.saved")
            }
            Text("选择会保存在这次判断里，之后还可以改。打算买只记录想法，这件衣服还不会加入衣橱。")
                .font(.footnote)
                .foregroundStyle(Color.tertiaryLabel)
        }
        .sensoryFeedback(.selection, trigger: model.call(for: decision.id))
    }
}

/// Read-only, user-facing conditions. Shopping snapshots never edit the brief
/// and never turn an unowned candidate into a wardrobe garment.
struct ShoppingDesignSummary: View {
    let constraints: Wire.StylingConstraints
    let title: String
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            SectionHeading(title: title)
            if let goal = constraints.goal, !goal.isEmpty { Text(goal) }
            if let style = constraints.targetStyle, !style.isEmpty, style != constraints.goal {
                Text("想尝试：\(StylingText.styles(style))")
            }
            if let scene = constraints.scene?.rawValue {
                Text("场合：\(ShoppingCopy.scene(scene))")
            }
            if let day = constraints.targetDate, let date = Garment.day(day) {
                Text("计划在\(date)穿")
            }
            if let ids = constraints.lockedItemIds, !ids.isEmpty {
                Text("保留：\(names(ids))")
            }
            if let ids = constraints.excludedItemIds, !ids.isEmpty {
                Text("这次不用：\(names(ids))")
            }
            ForEach(Array((constraints.notes ?? []).enumerated()), id: \.offset) { _, note in
                Text(note)
            }
            if constraints.inspirationId != nil { Text("带有这次的灵感来源。") }
            if constraints.exploration == true || !(constraints.preferenceOverrides ?? []).isEmpty {
                Text("这是这次的尝试，长期偏好仍然保留。")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color.secondaryLabel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shopping.designContext")
    }

    private func names(_ ids: [String]) -> String {
        ids.map { app.wardrobe.item($0)?.displayName ?? "当时选定的衣物" }.joined(separator: "、")
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

    static func scene(_ value: String) -> String {
        switch value {
        case "commute": "通勤"
        case "formal": "正式场合"
        case "casual": "日常休闲"
        case "date": "约会"
        case "travel": "出门旅行"
        default: value
        }
    }

    static func evaluatedDimension(_ value: String) -> String {
        switch value {
        case "owned_items": "已有衣物"
        case "locked_items": "本次保留的单品"
        case "excluded_items": "本次排除的单品"
        case "scene_evidence": "已有单品的场合标签和穿着记录"
        case "supporting_item_style_tags": "可搭单品已有的风格标签"
        default: "其他已记录的条件"
        }
    }

    static func unverifiedDimension(_ value: String) -> String {
        switch value {
        case "size_and_fit": "图片无法确认尺码和上身是否合适。"
        case "price_and_budget": "尚未核对价格与预算。"
        case "target_date_weather": "未查询计划当天的天气。"
        case "candidate_style": "候选衣服是否符合目标风格，还需进一步确认。"
        case "reference_visual_similarity": "还没有对比候选与灵感图的视觉相似性。"
        case "free_text_goals_and_notes": "你的目标和补充说明已保留，其中的细节尚未逐项核验。"
        case "preference_overrides": "这次放宽的偏好已保留，尚未逐项核对。"
        default: "还有部分条件尚未核验，结论仅供参考。"
        }
    }

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
