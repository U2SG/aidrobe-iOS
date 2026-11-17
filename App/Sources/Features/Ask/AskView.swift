import AidrobeKit
import SwiftUI

/// Ask the wardrobe a question. Each question leads into the answer and the
/// garments it names. `tools` is a slot under the suggestions for neighbouring
/// entries (purchase check, packing).
struct AskView<Tools: View>: View {
    @Environment(AppModel.self) private var app
    @State private var model: AskModel?
    @State private var draft = ""
    @State private var tripSource: PackingDesignSource?
    @State private var shopping: AskShoppingPresentation?
    @State private var purchaseToReveal: (conversationID: String, decisionID: String)?
    @State private var scrollPosition = ScrollPosition(idType: AskScrollTarget.self)
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
        .navigationDestination(for: Wire.StylingResponse.self) { styling in
            if let model { HistoricalStylingCard(model: model, styling: styling) }
        }
        .navigationDestination(for: AskPackingRoute.self) { route in
            if let model {
                PackingListDetailView(listID: route.listID, model: model.packing)
                    .toolbar(.visible, for: .navigationBar)
            }
        }
        .sheet(item: $tripSource, onDismiss: {
            Task { await model?.refreshSavedDesign() }
        }) { source in
            if let model {
                NewTripSheet(
                    model: model.packing, source: source, suggestedDays: model.tripDays,
                    onCreated: { id in
                        model.didCreatePackingList(id)
                        if model.packingListID == id {
                            scrollPosition.scrollTo(id: AskScrollTarget.packingList(id), anchor: .center)
                        }
                    }
                )
            }
        }
        .sheet(item: $shopping, onDismiss: {
            let target = purchaseToReveal
            purchaseToReveal = nil
            if let target, model?.conversationID == target.conversationID,
               model?.purchaseDecisions.contains(where: { $0.id == target.decisionID }) == true {
                scrollPosition.scrollTo(id: AskScrollTarget.purchase(target.decisionID), anchor: .center)
            }
            Task { await model?.refreshSavedDesign() }
        }) { presentation in
            NavigationStack {
                ShouldIBuyView(
                    source: presentation.source, decisionID: presentation.decisionID,
                    onDecision: presentation.onDecision,
                    onContinue: { conversationID in
                        shopping = nil
                        if model?.conversationID != conversationID { app.discussConversation(conversationID) }
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { shopping = nil }
                    }
                }
            }
        }
        .task(id: app.stylingChange) {
            if model == nil {
                model = AskModel(
                    api: app.api, wardrobe: app.wardrobe, bookmark: app.conversationBookmark,
                    onRevision: app.stylingDidChange, onFavoritesChange: app.favoritesDidChange
                )
            }
            if let conversationID = app.conversationToDiscuss {
                await model?.reopenConversation(conversationID)
                guard !Task.isCancelled else { return }
                if app.conversationToDiscuss == conversationID { app.conversationToDiscuss = nil }
                // Keep a failed explicit handoff visible. Loading the previous
                // bookmark here could make another conversation look successful.
                return
            } else if let inspiration = app.inspirationToDiscuss {
                model?.beginDesign(from: inspiration)
                app.inspirationToDiscuss = nil
                draft = AskModel.inspirationPrompt
                isTyping = true
            } else if let outfit = app.outfitToDiscuss {
                model?.beginDesign(from: outfit)
                app.outfitToDiscuss = nil
            }
            await model?.load()
        }
    }

    private func page(_ model: AskModel) -> some View {
        @Bindable var model = model
        @Bindable var actions = model.outfitActions
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                header(model)
                if model.usesInspiration { inspirationReference(model) }
                if let base = model.baseOutfit, model.entries.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.control) {
                        SectionHeading(title: "从这一套接着聊")
                        Text(base.title).font(.display(22, relativeTo: .title2))
                        OutfitBoard(items: model.outfitActions.boardItems(for: base, useOriginalPhotoFallback: true))
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
                ForEach(timeline(for: model)) { item in
                    switch item {
                    case let .turn(entry):
                        AskEntryView(entry: entry, model: model)
                            .id(item.id)
                    case let .packingList(list):
                        savedPackingList(list)
                            .id(item.id)
                    case let .purchase(decision):
                        savedPurchase(decision, model: model)
                            .id(item.id)
                    }
                }
                if model.needsOutfitUpdate, model.styling != nil {
                    VStack(alignment: .leading, spacing: Spacing.control) {
                        SectionHeading(title: "待应用的新条件")
                        DesignConditions(model: model)
                    }
                }
                if let styling = model.styling {
                    StylingCard(model: model, styling: styling, onPacking: {
                        isTyping = false
                        tripSource = PackingDesignSource(
                            conversationID: styling.conversationId,
                            revision: model.expectedRevision ?? styling.revision
                        )
                    })
                    .id(styling.outfit.outfitId)
                } else if model.designBrief != nil {
                    VStack(alignment: .leading, spacing: Spacing.row) {
                        SectionHeading(title: model.needsOutfitUpdate ? "待应用的新条件" : "条件已记下")
                        DesignConditions(model: model)
                        Text("继续聊聊，按这些条件生成方案后再采用。")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondaryLabel)
                    }
                }
                if model.shoppingSource != nil {
                    Button("看看要不要买", systemImage: "bag") {
                        isTyping = false
                        openShopping(model)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(model.isBusy || model.needsLatestVersion || model.hasUnresolvedQuestion)
                    .accessibilityIdentifier("ask.shopping")
                }
                if !model.hasConversation && !model.isRestoring { opening(model) }
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screen)
            .padding(.top, Spacing.tight)
            .padding(.bottom, Spacing.section)
        }
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.entries.last?.id, initial: true) { _, id in
            if let id {
                scrollPosition.scrollTo(id: AskScrollTarget.turn(id), anchor: .top)
            }
        }
        .safeAreaBar(edge: .bottom) { inputBar(model) }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .toast($model.notice)
        .toast($actions.notice)
    }

    private func timeline(for model: AskModel) -> [AskTimelineItem] {
        var items = model.entries.map(AskTimelineItem.turn)
        if let list = model.packingList { items.append(.packingList(list)) }
        items.append(contentsOf: model.purchaseDecisions.map(AskTimelineItem.purchase))
        let fallbackDate = model.entries.first?.createdAt ?? .distantPast
        return items.sorted {
            let left = $0.createdAt ?? fallbackDate
            let right = $1.createdAt ?? fallbackDate
            return left == right ? $0.sortKey < $1.sortKey : left < right
        }
    }

    private func openShopping(_ model: AskModel, decisionID: String? = nil) {
        purchaseToReveal = nil
        let receive = model.purchaseReceiver()
        shopping = AskShoppingPresentation(
            source: model.shoppingSource, decisionID: decisionID, onDecision: { decision in
                receive(decision)
                guard let conversationID = decision.designContext?.conversationId,
                      model.conversationID == conversationID,
                      model.purchaseDecisions.contains(where: { $0.id == decision.id }) else { return }
                purchaseToReveal = (conversationID, decision.id)
            }
        )
    }

    private func savedPurchase(_ decision: Wire.WardrobeDecisionResponse, model: AskModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            SectionHeading(title: "看过的候选")
            Button {
                openShopping(model, decisionID: decision.id)
            } label: {
                HStack(alignment: .top, spacing: Spacing.row) {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(decision.decisionText)
                            .font(.body).foregroundStyle(Color.label)
                        if let goal = decision.designContext?.constraints.goal, !goal.isEmpty {
                            Text("当时想要：\(goal)")
                                .font(.subheadline).foregroundStyle(Color.secondaryLabel)
                        }
                        if let raw = decision.choice?.rawValue, let call = AskedPurchase.Call(rawValue: raw) {
                            Text(call.title).font(.subheadline).foregroundStyle(Color.accent)
                        }
                        Text(decision.createdAt.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN"))))
                            .font(.caption).foregroundStyle(Color.tertiaryLabel)
                    }
                    Spacer(minLength: Spacing.tight)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Color.tertiaryLabel)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityIdentifier("ask.purchaseDecision.\(decision.id)")
            .accessibilityHint("回看当时的条件和判断，或修改购买选择")
            Divider().overlay(Color.separator)
        }
    }

    private func header(_ model: AskModel) -> some View {
        let title = if model.usesInspiration && model.entries.isEmpty { "从灵感开始设计" }
        else if model.hasConversation { "接着问" }
        else { "想问衣橱什么？" }
        return VStack(alignment: .leading, spacing: 6) {
            Text("问问").kicker()
            HStack(alignment: .bottom) {
                Text(title)
                    .font(model.hasConversation
                          ? .display(24, relativeTo: .title2)
                          : .display(34, weight: .black, relativeTo: .largeTitle))
                    .foregroundStyle(Color.label)
                Spacer()
                if model.hasConversation || model.restorationFailure != nil {
                    Button {
                        draft = ""
                        isTyping = false
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
            if !model.hasConversation {
                Text("只用你衣橱里真有的衣服来回答。")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }

    private func inspirationReference(_ model: AskModel) -> some View {
        HStack(spacing: Spacing.control) {
            if let imageURL = model.inspiration?.imageUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.elevatedBackground
                }
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: Radius.tile))
                .accessibilityHidden(true)
            }
            Label("参考这张灵感图", systemImage: "photo")
                .font(.subheadline)
                .foregroundStyle(Color.secondaryLabel)
        }
    }

    private func savedPackingList(_ list: Wire.PackingListResponse) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            SectionHeading(title: "已保存的打包清单")
            NavigationLink(value: AskPackingRoute(listID: list.packingListId)) {
                TripRow(list: list)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.packingList")
            .accessibilityHint("查看打包清单")
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
            if model.hasUnresolvedQuestion {
                Text("上一句还没确认结果。请重试那一句，或开启新对话后再聊。")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryLabel)
            }
            GlassEffectContainer(spacing: Spacing.tight) {
                HStack(alignment: .bottom, spacing: Spacing.tight) {
                    TextField("说说想法，或调整这一套", text: $draft, axis: .vertical)
                        .accessibilityIdentifier("ask.message")
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
                    .accessibilityIdentifier("ask.send")
                }
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.bottom, Spacing.tight)
    }

    private func send(_ question: String, _ model: AskModel) {
        guard model.ask(question) else { return }
        if draft == question { draft = "" }
        isTyping = false
    }
}

extension AskView where Tools == EmptyView {
    init() {
        self.init { EmptyView() }
    }
}

private struct AskPackingRoute: Hashable {
    let listID: String
}

private struct AskShoppingPresentation: Identifiable {
    let id = UUID()
    let source: ShoppingDesignSource?
    let decisionID: String?
    let onDecision: (Wire.WardrobeDecisionResponse) -> Void
}

private enum AskScrollTarget: Hashable, Sendable {
    case turn(UUID)
    case packingList(String)
    case purchase(String)
}

private enum AskTimelineItem: Identifiable {
    case turn(AskModel.Entry)
    case packingList(Wire.PackingListResponse)
    case purchase(Wire.WardrobeDecisionResponse)

    var id: AskScrollTarget {
        switch self {
        case let .turn(entry): .turn(entry.id)
        case let .packingList(list): .packingList(list.packingListId)
        case let .purchase(decision): .purchase(decision.id)
        }
    }

    var createdAt: Date? {
        switch self {
        case let .turn(entry): entry.createdAt
        case let .packingList(list): list.createdAt
        case let .purchase(decision): decision.createdAt
        }
    }

    /// Stable tie-breakers retain the same order after reopening a conversation.
    var sortKey: String {
        switch self {
        case let .turn(entry): "0-\(entry.id)"
        case let .packingList(list): "1-\(list.packingListId)"
        case let .purchase(decision): "2-\(decision.id)"
        }
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
    let onPacking: () -> Void
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
                Text("新条件还没有应用到这一套。继续聊聊，生成新方案后再采用。")
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
            Button("出行打包", systemImage: "suitcase", action: onPacking)
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(model.isBusy || model.needsLatestVersion || model.needsOutfitUpdate)
            WearFeedbackButton(model: model, styling: styling)
            if !showPieces, let image = actions.generatedImages[outfit.outfitId] {
                GarmentImage(url: image, forceOriginal: true, fit: true, photoAspectRatio: 2.0 / 3.0)
                    .accessibilityHidden(false)
                    .accessibilityLabel("当前搭配的整套效果图")
            } else {
                OutfitBoard(items: actions.boardItems(for: outfit, useOriginalPhotoFallback: true)) { item in
                    openReplacement(item)
                }
            }
            imageAction
            Text(outfit.reason)
                .font(.body)
                .foregroundStyle(Color.secondaryLabel)
            if !model.needsOutfitUpdate { DesignConditions(model: model) }
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
                    .disabled(actions.changingFavorites.contains(outfit.outfitId))
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

private struct HistoricalStylingCard: View {
    let model: AskModel
    let styling: Wire.StylingResponse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.row) {
                Text(styling.outfit.title)
                    .font(.display(24, relativeTo: .title2))
                    .foregroundStyle(Color.label)
                WearFeedbackButton(model: model, styling: styling)
                OutfitBoard(items: model.outfitActions.boardItems(
                    for: styling.outfit, useOriginalPhotoFallback: true
                ))
                Text(styling.outfit.reason)
                    .foregroundStyle(Color.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .background(Color.background)
        .navigationTitle("第\(styling.revision)版搭配")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct WearFeedbackButton: View {
    let model: AskModel
    let styling: Wire.StylingResponse
    @State private var isOpen = false

    var body: some View {
        Button(
            model.hasWearFeedback(for: styling) ? "修改穿着感受" : "记录穿着感受",
            systemImage: "square.and.pencil"
        ) {
            isOpen = true
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .accessibilityIdentifier("ask.wearFeedback")
        .sheet(isPresented: $isOpen) {
            DesignFeedbackSheet(styling: styling, model: model)
        }
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
                    Text("想尝试：\(StylingText.styles(style))")
                }
                if constraints.exploration == true {
                    Text("这是本次尝试，不会自动改掉长期偏好。")
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
                .font(.body.weight(.semibold))
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
                if entry.needsOutfitUpdate {
                    Text("本次已记下新条件，还没有生成新搭配。")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if let styling = entry.styling {
                    NavigationLink(value: styling) {
                        Label(
                            entry.needsOutfitUpdate ? "查看上一套（第\(styling.revision)版）" : "查看第\(styling.revision)版搭配",
                            systemImage: "square.stack"
                        )
                            .font(.subheadline)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("ask.stylingRevision.\(styling.revision)")
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

    private var feedback: some View {
        HStack(spacing: 0) {
            feedbackButton(.like, title: "有帮助", symbol: "hand.thumbsup")
            feedbackButton(.dislike, title: "没帮上", symbol: "hand.thumbsdown")
        }
    }

    private func feedbackButton(_ kind: FeedbackKind, title: String, symbol: String) -> some View {
        let isSelected = entry.feedback == kind
        return Button {
            Task { await model.sendFeedback(kind, for: entry) }
        } label: {
            Image(systemName: isSelected ? "\(symbol).fill" : symbol)
                .font(.subheadline)
                .foregroundStyle(isSelected ? Color.accent : Color.secondaryLabel)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(entry.feedback != nil)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
