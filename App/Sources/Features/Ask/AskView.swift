import AidrobeKit
import SwiftUI

/// Ask the wardrobe a question. Reads like a column, not a chat: each question
/// is a headline, the answer is body text, and the garments it names are laid
/// out beneath. `tools` is a slot under the suggestions for neighbouring
/// entries (purchase check, packing).
struct AskView<Tools: View>: View {
    @Environment(AppModel.self) private var app
    @State private var model: AskModel?
    @State private var draft = ""
    @FocusState private var isTyping: Bool
    private let tools: Tools

    init(@ViewBuilder tools: () -> Tools) {
        self.tools = tools()
    }

    private let suggestions = ["今天降温了，怎么穿", "周五面试穿什么", "哪些衣服很久没穿了", "周末出门两天带什么"]

    var body: some View {
        // ZStack, not Group: the task that creates the model must attach to something.
        ZStack {
            if let model { page(model) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { ItemDetailView(itemID: $0) }
        .task(id: app.stylingChange) {
            if model == nil {
                model = AskModel(
                    api: app.api, wardrobe: app.wardrobe, bookmark: app.conversationBookmark,
                    onRevision: app.stylingDidChange
                )
            }
            if let outfit = app.outfitToDiscuss {
                model?.beginDesign(from: outfit)
                app.outfitToDiscuss = nil
            }
            if let referenceID = app.referenceToDiscuss {
                model?.beginDesign(referenceID: referenceID)
                draft = "参考这张图，帮我用衣橱搭一套"
                app.referenceToDiscuss = nil
            }
            await model?.load()
        }
    }

    private func page(_ model: AskModel) -> some View {
        @Bindable var model = model
        @Bindable var actions = model.outfitActions
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    header(model)
                    if let base = model.baseOutfit, model.entries.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.control) {
                            SectionHeading(title: "从这一套接着聊")
                            Text(base.title).font(.display(22, relativeTo: .title2))
                            OutfitBoard(items: model.outfitActions.boardItems(for: base))
                            Text("想保留哪件，或者哪里想调整？")
                                .font(.subheadline).foregroundStyle(Color.secondaryLabel)
                        }
                    }
                    if model.isRestoring { ProgressView("正在取回这段对话…") }
                    if let failure = model.restorationFailure {
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(failure).font(.subheadline).foregroundStyle(Color.secondaryLabel)
                            if model.canRetryRestore {
                                Button("重新读取") { Task { await model.retryRestore() } }
                                    .buttonStyle(.glass)
                                    .disabled(model.isBusy)
                            }
                        }
                    }
                    ForEach(model.entries) { entry in
                        if let linked = entry.linkedResult {
                            LinkedDesignResultView(result: linked).id(entry.id)
                        } else {
                            AskEntryView(entry: entry, model: model).id(entry.id)
                        }
                    }
                    if let styling = model.styling {
                        StylingCard(model: model, styling: styling)
                            .id(styling.outfit.outfitId)
                    } else if model.designBrief != nil {
                        VStack(alignment: .leading, spacing: Spacing.row) {
                            SectionHeading(title: "条件已记下")
                            DesignConditions(model: model)
                            Text("继续聊聊，按这些条件生成方案后再采用。")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondaryLabel)
                            DesignNextSteps(model: model)
                        }
                    }
                    if model.entries.isEmpty && model.styling == nil && model.designBrief == nil && model.baseOutfit == nil && !model.isRestoring { opening(model) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.screen)
                .padding(.top, Spacing.tight)
                .padding(.bottom, Spacing.section)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.entries.count) {
                guard let last = model.entries.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .top) }
            }
        }
        .safeAreaBar(edge: .bottom) { inputBar(model) }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .toast($model.notice)
        .toast($actions.notice)
    }

    private func header(_ model: AskModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("问问").kicker()
            HStack(alignment: .bottom) {
                Text(model.entries.isEmpty && model.styling == nil && model.designBrief == nil && model.baseOutfit == nil ? "想问衣橱什么？" : "接着问")
                    .font(.display(34, weight: .black, relativeTo: .largeTitle))
                    .foregroundStyle(Color.label)
                Spacer()
                if !model.entries.isEmpty || model.styling != nil || model.designBrief != nil || model.baseOutfit != nil || model.referenceDraftID != nil || model.restorationFailure != nil {
                    Button {
                        draft = ""
                        Task { await model.startOver() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(model.isBusy)
                    .accessibilityLabel("新对话")
                }
            }
            if model.entries.isEmpty && model.styling == nil && model.designBrief == nil && model.baseOutfit == nil {
                Text("只用你衣橱里真有的衣服来回答。")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }

    /// Before the first question: things to ask, neighbouring tools, earlier questions.
    @ViewBuilder private func opening(_ model: AskModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            SectionHeading(title: "可以这样问")
            FlowLayout {
                ForEach(suggestions, id: \.self) { suggestion in
                    Chip(title: suggestion, isSelected: false) { send(suggestion, model) }
                }
            }
        }
        if Tools.self != EmptyView.self { toolsSection }
        if !model.earlier.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "之前问过")
                    .padding(.bottom, 4)
                ForEach(model.earlier.prefix(8), id: \.askSessionId) { item in
                    Button {
                        Task { await model.reopen(item) }
                    } label: {
                        HStack(spacing: Spacing.row) {
                            Text(item.question)
                                .font(.body)
                                .foregroundStyle(Color.label)
                                .lineLimit(1)
                            Spacer(minLength: Spacing.tight)
                            Text(item.createdAt.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))
                                .font(.subheadline)
                                .foregroundStyle(Color.tertiaryLabel)
                        }
                        .frame(minHeight: 48)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                    Divider().overlay(Color.separator)
                }
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeading(title: "也可以")
            tools
        }
    }

    private func inputBar(_ model: AskModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if model.referenceDraftID != nil {
                HStack {
                    Text("参考了灵感图").font(.footnote).foregroundStyle(Color.secondaryLabel)
                    Spacer()
                    Button("不参考这张图") {
                        model.clearReferenceDraft()
                        if draft == "参考这张图，帮我用衣橱搭一套" { draft = "" }
                    }
                        .font(.footnote)
                        .disabled(model.isBusy)
                }
            }
            if model.hasUnresolvedQuestion {
                Text("上一句还没确认结果。请重试那一句，或开启新对话后再聊。")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryLabel)
            }
            GlassEffectContainer(spacing: Spacing.tight) {
                HStack(alignment: .bottom, spacing: Spacing.tight) {
                    TextField("说说想法，或调整这一套", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($isTyping)
                        .submitLabel(.send)
                        .onSubmit { send(draft, model) }
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, 13)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
                    Button {
                        send(draft, model)
                    } label: {
                        Group {
                            if model.isBusy {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.up").fontWeight(.semibold)
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .disabled(!model.canAsk || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.bottom, Spacing.tight)
    }

    private func send(_ question: String, _ model: AskModel) {
        guard model.canAsk else { return }
        draft = ""
        isTyping = false
        Task { await model.ask(question) }
    }
}

extension AskView where Tools == EmptyView {
    init() {
        self.init { EmptyView() }
    }
}

private struct StylingSwapTarget: Identifiable {
    let outfit: Wire.OutfitResponse
    let item: BoardItem
    var id: String { outfit.outfitId + item.itemID }
}

/// A saved outfit is the working result. The conversation can keep changing
/// while image work finishes against its own immutable outfit identifier.
private struct StylingCard: View {
    let model: AskModel
    let styling: Wire.StylingResponse
    @State private var swapTarget: StylingSwapTarget?
    @State private var showPieces = false

    private var outfit: Wire.OutfitResponse { styling.outfit }
    private var actions: TodayModel { model.outfitActions }
    private var adoptionTitle: String {
        if styling.status == .adopted {
            if let day = styling.recommendationDate, day != JournalDay.today {
                return "已安排在\(Garment.day(day) ?? day)"
            }
            return "已放到今日"
        }
        if let day = model.designConstraints?.targetDate, day > JournalDay.today {
            return "安排在\(Garment.day(day) ?? day)"
        }
        return "就这套，放到今日"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            SectionHeading(title: model.needsOutfitUpdate ? "上一套搭配" : "这一套")
            if model.needsOutfitUpdate {
                Text("条件已记下。继续聊聊，按这些条件更新方案后再采用。")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(outfit.title)
                    .font(.display(24, relativeTo: .title2))
                    .foregroundStyle(Color.label)
                Spacer(minLength: Spacing.tight)
                Text("第\(styling.revision)版")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.tertiaryLabel)
            }
            if !showPieces, let image = actions.generatedImages[outfit.outfitId] {
                GarmentImage(url: image, forceOriginal: true, fit: true, photoAspectRatio: 2.0 / 3.0)
                    .accessibilityHidden(false)
                    .accessibilityLabel("当前搭配的整套效果图")
            } else {
                OutfitBoard(items: actions.boardItems(for: outfit)) { item in
                    openReplacement(item)
                }
            }
            imageAction
            Text(outfit.reason)
                .font(.body)
                .foregroundStyle(Color.secondaryLabel)
            DesignConditions(model: model)
            pieces
            if model.isUpdatingDesign { ProgressView("正在保存修改…") }
            if let failure = model.actionFailure {
                Text(failure).font(.subheadline).foregroundStyle(Color.secondaryLabel)
                if model.canRetryAction {
                    Button("重试刚才的操作") { Task { await model.retryDesignAction() } }
                        .buttonStyle(.glass)
                        .disabled(model.isBusy || model.needsLatestVersion)
                }
            }
            HStack(spacing: Spacing.control) {
                Button {
                    Task { await model.adopt() }
                } label: {
                    Text(adoptionTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.isBusy || model.needsLatestVersion || model.needsOutfitUpdate || styling.status == .adopted)
                Menu {
                    Button(
                        actions.favoriteOutfitIDs.contains(outfit.outfitId) ? "取消收藏" : "收藏这套",
                        systemImage: "heart"
                    ) { Task { await actions.toggleFavorite(outfit) } }
                    if styling.status == .adopted, styling.recommendationDate == JournalDay.today {
                        Button(
                            actions.wornOutfitIDs.contains(outfit.outfitId) ? "已记录穿着" : "今天穿了这套",
                            systemImage: "checkmark"
                        ) { Task { await actions.markWorn(outfit) } }
                        .disabled(actions.wornOutfitIDs.contains(outfit.outfitId))
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(model.isBusy)
                .accessibilityLabel("这套搭配的操作")
            }
            if !model.needsOutfitUpdate {
                StylingExperienceView(
                    outfitID: outfit.outfitId, conversationID: styling.conversationId,
                    revision: styling.revision, refreshID: actions.wornOutfitIDs.contains(outfit.outfitId)
                )
                .id(outfit.outfitId)
                .disabled(model.isBusy)
            }
            DesignNextSteps(model: model)
        }
        .task(id: outfit.outfitId) { await actions.loadGeneratedImage(for: outfit.outfitId) }
        .sheet(item: $swapTarget) { target in
            SwapSheet(
                outfit: target.outfit, slot: target.item, model: actions,
                onRevision: model.acceptRevision, onConflict: { await model.restoreCurrent() }
            )
        }
    }

    @ViewBuilder private var imageAction: some View {
        let id = outfit.outfitId
        if actions.generatedImages[id] != nil {
            Button(showPieces ? "看整套效果" : "看单品拼图") { showPieces.toggle() }
                .font(.footnote)
        } else if actions.generatingOutfits.contains(id) {
            ProgressView("正在准备整套图…").font(.footnote)
        } else {
            if let issue = actions.outfitImageIssues[id] {
                Text(issue).font(.footnote).foregroundStyle(Color.secondaryLabel)
            }
            Button("看一下整套效果", systemImage: "sparkles") {
                Task { await actions.generateImage(for: outfit) }
            }
            .buttonStyle(.glass)
            .disabled(model.isBusy)
        }
    }

    private var pieces: some View {
        VStack(spacing: 0) {
            ForEach(actions.boardItems(for: outfit)) { item in
                let locked = model.lockedItemIDs.contains(item.itemID)
                HStack(spacing: Spacing.control) {
                    Text(Garment.category(item.role))
                        .font(.caption)
                        .foregroundStyle(Color.tertiaryLabel)
                        .frame(width: 48, alignment: .leading)
                    Text(item.name)
                        .font(.subheadline)
                        .foregroundStyle(Color.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button("换一件", systemImage: "arrow.triangle.2.circlepath") { openReplacement(item) }
                            .disabled(locked)
                        Button(locked ? "取消保留" : "保留这件", systemImage: locked ? "lock.open" : "lock") {
                            Task { await model.toggleLock(item.itemID) }
                        }
                    } label: {
                        Label(locked ? "已保留" : "调整", systemImage: locked ? "lock" : "ellipsis")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                    }
                    .disabled(model.isBusy || model.needsLatestVersion || model.needsOutfitUpdate)
                    .accessibilityLabel("调整\(item.name)")
                }
                Divider().overlay(Color.separator)
            }
        }
    }

    private func openReplacement(_ item: BoardItem) {
        guard !model.isBusy, !model.needsLatestVersion, !model.needsOutfitUpdate else { return }
        if model.lockedItemIDs.contains(item.itemID) {
            model.notice = "这件已经保留。取消保留后，可以再换一件。"
        } else { swapTarget = StylingSwapTarget(outfit: outfit, item: item) }
    }
}

private struct DesignConditions: View {
    let model: AskModel

    var body: some View {
        if let constraints = model.designConstraints {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let day = constraints.targetDate, let date = Garment.day(day) {
                    if day < JournalDay.today {
                        Text("这份计划的日期已过，采用时会放到今日。")
                    } else { Text("准备在\(date)穿") }
                }
                if let goal = constraints.goal, !goal.isEmpty {
                    Text("这次想要：\(goal)")
                }
                if let style = constraints.targetStyle, !style.isEmpty, style != constraints.goal {
                    Text("想尝试：\(style)")
                }
                if constraints.exploration == true {
                    Text("这是本次尝试，不会自动改掉长期偏好。")
                }
                if constraints.referenceInspirationId != nil {
                    Text("参考了灵感图")
                        .font(.caption).foregroundStyle(Color.secondaryLabel)
                }
                ForEach(Array((constraints.notes ?? []).enumerated()), id: \.offset) { _, note in
                    Text(note)
                }
                if !model.lockedItemIDs.isEmpty {
                    Text("保留：\(model.lockedItemIDs.map(model.itemName).joined(separator: "、"))")
                }
                if !model.excludedItemIDs.isEmpty {
                    Text("这次不用")
                        .foregroundStyle(Color.tertiaryLabel)
                    FlowLayout {
                        ForEach(model.excludedItemIDs, id: \.self) { id in
                            Button {
                                Task { await model.removeExclusion(id) }
                            } label: {
                                Label(model.itemName(id), systemImage: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy || model.needsLatestVersion || model.needsOutfitUpdate)
                            .accessibilityLabel("取消本次排除：\(model.itemName(id))")
                        }
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.secondaryLabel)
        }
    }
}

/// One question and what came back.
private struct AskEntryView: View {
    let entry: AskModel.Entry
    let model: AskModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            Divider().overlay(Color.separator)
            Text(entry.question)
                .font(.display(22, relativeTo: .title2))
                .foregroundStyle(Color.label)
            switch entry.state {
            case .asking:
                HStack(spacing: Spacing.tight) {
                    ProgressView()
                    Text("正在翻你的衣橱…")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
            case let .answered(_, text, garments):
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                if let styling = entry.styling {
                    Text("第\(styling.revision)版搭配")
                        .font(.caption)
                        .foregroundStyle(Color.tertiaryLabel)
                    if styling.outfit.outfitId != model.styling?.outfit.outfitId, !garments.isEmpty {
                        garmentRow(garments)
                    }
                } else if !garments.isEmpty { garmentRow(garments) }
                if model.canGiveFeedback(entry) { feedback }
            case .unavailable:
                note("问问暂时还答不了，可以稍后重试。")
                recovery
            case let .failed(message):
                note(message)
                recovery
            }
        }
    }

    private var recovery: some View {
        HStack(spacing: Spacing.control) {
            Button("再问一次") { Task { await model.retry(entry) } }
                .buttonStyle(.glass)
                .disabled(model.isBusy || model.needsLatestVersion)
            Button("新对话") { Task { await model.startOver() } }
                .buttonStyle(.glass)
                .disabled(model.isBusy)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Color.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.row)
            .background(Color.fill, in: .rect(cornerRadius: Radius.tile))
    }

    private func garmentRow(_ garments: [AskGarment]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Spacing.control) {
                ForEach(garments) { garment in
                    if garment.isInWardrobe {
                        NavigationLink(value: garment.id) { tile(garment) }
                            .buttonStyle(.plain)
                    } else {
                        tile(garment)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        // Bleed to the screen edge so the row scrolls under the page margin.
        .contentMargins(.horizontal, Spacing.screen, for: .scrollContent)
        .padding(.horizontal, -Spacing.screen)
    }

    private func tile(_ garment: AskGarment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GarmentImage(url: garment.imageURL)
                .frame(width: 104, height: 130)
                .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.tile))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.separator))
            Text(garment.name)
                .font(.caption)
                .foregroundStyle(Color.secondaryLabel)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 104, alignment: .leading)
        }
    }

    @ViewBuilder private var feedback: some View {
        if let given = entry.feedback {
            Text(given == .dislike ? "记下了，这次答得不好" : "记下了，谢谢")
                .font(.subheadline)
                .foregroundStyle(Color.tertiaryLabel)
        } else {
            HStack(spacing: Spacing.tight) {
                Text("这个回答")
                    .font(.subheadline)
                    .foregroundStyle(Color.tertiaryLabel)
                Chip(title: "有帮助", isSelected: false) {
                    Task { await model.sendFeedback(.like, for: entry) }
                }
                Chip(title: "没帮上", isSelected: false) {
                    Task { await model.sendFeedback(.dislike, for: entry) }
                }
            }
        }
    }
}

private struct DesignNextSteps: View {
    let model: AskModel
    @Environment(AppModel.self) private var app

    var body: some View {
        if let context = model.designContext {
            VStack(alignment: .leading, spacing: Spacing.control) {
                if app.environment.flags.purchaseDecision {
                    NavigationLink("看看要不要添一件") { ShouldIBuyView(designContext: context) }
                }
                NavigationLink("带着这些想法去旅行") { PackingListsView(designContext: context) }
            }
            .font(.subheadline)
            .disabled(model.isBusy || model.hasUnresolvedQuestion || model.needsLatestVersion)
        }
    }
}

private struct LinkedDesignResultView: View {
    let result: Wire.LinkedDesignResult
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            Text(result.summary).font(.body).foregroundStyle(Color.secondaryLabel)
            if result.kind == .purchaseDecision {
                if app.environment.flags.purchaseDecision {
                    NavigationLink("查看购买参考") { ShouldIBuyView(decisionID: result.resourceId) }
                }
            } else {
                NavigationLink("查看打包清单") { PackingListsView(initialListID: result.resourceId) }
            }
        }
        .padding(.vertical, Spacing.control)
    }
}
