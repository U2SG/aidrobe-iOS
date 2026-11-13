import AidrobeKit
import SwiftUI

/// Today reads as one page of a daily: the date, one outfit laid out from the
/// user's own garments, why it was chosen, and a single decision to make.
struct TodayView: View {
    @Environment(AppModel.self) private var app
    @State private var model: TodayModel?

    var body: some View {
        // ZStack, not Group: with no model yet a Group is empty and its
        // modifiers (including the task that creates the model) attach to nothing.
        ZStack {
            if let model {
                switch model.phase {
                case .loading:
                    ProgressView("正在看你的衣橱…")
                case let .failed(message):
                    ContentUnavailableView {
                        Label("没能拿到今天的搭配", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("再试一次") { Task { await model.load() } }
                            .buttonStyle(.glass)
                    }
                case .loaded:
                    if model.isReady {
                        TodayPage(model: model)
                    } else {
                        TodayEmptyPage(guidance: model.today?.guidanceText) { await model.load() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if model == nil { model = TodayModel(api: app.api, wardrobe: app.wardrobe) }
            await model?.load()
        }
    }
}

private struct TodayHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date.now.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                .kicker()
            Text(title)
                .font(.display(34, weight: .black, relativeTo: .largeTitle))
                .foregroundStyle(Color.label)
        }
    }
}

private struct TodayEmptyPage: View {
    let guidance: String?
    let reload: () async -> Void
    @State private var isImporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.row) {
                TodayHeader(title: "还搭不出一套")
                Text(guidance ?? "衣橱里至少要有一件上装、一件下装和一双鞋。先放进几件常穿的，明早就有搭配。")
                    .font(.body)
                    .foregroundStyle(Color.secondaryLabel)
                Button("添加衣物") { isImporting = true }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, Spacing.tight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .refreshable { await reload() }
        .sheet(isPresented: $isImporting) {
            ImportFlowView { Task { await reload() } }
        }
    }
}

private struct SwapTarget: Identifiable {
    let outfit: Wire.OutfitResponse
    let slot: BoardItem

    var id: String { outfit.outfitId + slot.slotID }
}

private struct TodayPage: View {
    let model: TodayModel
    @State private var currentID: String?
    @State private var swapTarget: SwapTarget?
    @State private var feedbackOutfit: Wire.OutfitResponse?
    @State private var showsContext = false

    private var outfit: Wire.OutfitResponse {
        model.outfits.first { $0.outfitId == currentID } ?? model.outfits[0]
    }

    private var isWorn: Bool { model.wornOutfitIDs.contains(outfit.outfitId) }

    var body: some View {
        // A refresh can come back empty; the parent swaps this page out, but
        // never index into an empty list on the way.
        if !model.outfits.isEmpty { page }
    }

    private var page: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, Spacing.screen)
                    .padding(.top, Spacing.tight)
                pager
                    .padding(.top, Spacing.row)
                VStack(alignment: .leading, spacing: Spacing.section) {
                    caption
                    pieces
                    reasons
                    prep
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.top, Spacing.row)
                .padding(.bottom, Spacing.section)
            }
        }
        .refreshable { await model.load() }
        .safeAreaBar(edge: .bottom) { actionBar }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .toast($model.notice)
        .sheet(item: $swapTarget) { target in
            SwapSheet(outfit: target.outfit, slot: target.slot, model: model)
        }
        .sheet(item: $feedbackOutfit) { outfit in
            FeedbackSheet(outfit: outfit, model: model)
        }
        .sheet(isPresented: $showsContext) {
            ContextSheet(model: model)
        }
        .sensoryFeedback(.success, trigger: model.wornOutfitIDs)
        .sensoryFeedback(.selection, trigger: currentID)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            HStack(alignment: .bottom) {
                TodayHeader(title: isWorn ? "今天就这套" : "今天穿这套")
                Spacer()
                Button {
                    showsContext = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("今天的情况")
            }
            if let line = contextLine {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }

    /// Weather and any situation the user stated, in one quiet line.
    private var contextLine: String? {
        var parts: [String] = []
        if let weather = model.weather {
            parts.append("\(weather.condition) \(Int(weather.temperatureC.rounded()))°")
            if abs(weather.feelsLikeC - weather.temperatureC) >= 2 {
                parts.append("体感 \(Int(weather.feelsLikeC.rounded()))°")
            }
            if weather.rainProbability >= 0.3 {
                parts.append("降雨 \(Int((weather.rainProbability * 100).rounded()))%")
            }
            if let place = weather.locationName { parts.append(place) }
        }
        if let chip = model.appliedChip { parts.append("已按「\(chip.title)」搭配") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Board

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Spacing.control) {
                ForEach(model.outfits) { outfit in
                    OutfitBoard(items: model.boardItems(for: outfit)) { slot in
                        swapTarget = SwapTarget(outfit: outfit, slot: slot)
                    }
                    .overlay(alignment: .topTrailing) { favoriteButton(outfit) }
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Spacing.screen, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
    }

    private func favoriteButton(_ outfit: Wire.OutfitResponse) -> some View {
        let isFavorite = model.favoriteOutfitIDs.contains(outfit.outfitId)
        return Button {
            Task { await model.toggleFavorite(outfit) }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.body)
                .foregroundStyle(isFavorite ? Color.accent : Color.tertiaryLabel)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(4)
        .sensoryFeedback(.impact, trigger: isFavorite)
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏这套")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(outfit.title)
                    .font(.display(22, relativeTo: .title2))
                    .foregroundStyle(Color.label)
                Spacer()
                if model.outfits.count > 1, let index = model.outfits.firstIndex(where: { $0.outfitId == outfit.outfitId }) {
                    Text("\(index + 1) / \(model.outfits.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.tertiaryLabel)
                }
            }
            Text(outfit.reason)
                .font(.body)
                .foregroundStyle(Color.secondaryLabel)
        }
    }

    // MARK: Sections

    private var pieces: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "这一套")
                .padding(.bottom, 4)
            ForEach(model.boardItems(for: outfit)) { item in
                Button {
                    swapTarget = SwapTarget(outfit: outfit, slot: item)
                } label: {
                    HStack(spacing: Spacing.row) {
                        Text(Garment.category(item.role))
                            .font(.subheadline)
                            .foregroundStyle(Color.tertiaryLabel)
                            .frame(width: 52, alignment: .leading)
                        Text(item.name)
                            .font(.body)
                            .foregroundStyle(Color.label)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.tight)
                        Text(item.isSwapped ? "已换" : "换一件")
                            .font(.subheadline)
                            .foregroundStyle(item.isSwapped ? Color.accent : Color.tertiaryLabel)
                    }
                    .frame(minHeight: 48)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.separator)
            }
        }
    }

    @ViewBuilder private var reasons: some View {
        if let reasoning = outfit.reasoning, !reasoning.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.control) {
                SectionHeading(title: "为什么是这套")
                ForEach(Array(reasoning.prefix(3).enumerated()), id: \.offset) { index, reason in
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

    @ViewBuilder private var prep: some View {
        // "Fetch these pieces" only repeats the list above; show real preparation (ironing, drying).
        let steps = (outfit.prepSteps ?? []).filter { $0.key != "prep.fetch_unknown" }
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.control) {
                SectionHeading(title: "出门前")
                ForEach(steps, id: \.key) { step in
                    Text(step.fallbackText)
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                }
            }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        GlassEffectContainer(spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                Button {
                    Task { await another() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().frame(width: 72)
                    } else {
                        Text(model.outfits.count > 1 ? "换一套" : "重新搭")
                    }
                }
                .buttonStyle(.glass)
                .disabled(model.isRefreshing)

                if isWorn {
                    Button {
                        feedbackOutfit = outfit
                    } label: {
                        Text(model.feedbackByOutfit[outfit.outfitId] == nil ? "说说穿着感受" : "已记下感受")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else {
                    Button {
                        Task { await model.markWorn(outfit) }
                    } label: {
                        Text("就穿这套").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        feedbackOutfit = outfit
                    } label: {
                        Image(systemName: "hand.thumbsdown")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("这套不合适")
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.bottom, Spacing.tight)
    }

    /// Next prepared outfit, or a fresh set when there is only one.
    private func another() async {
        let outfits = model.outfits
        guard outfits.count > 1, let index = outfits.firstIndex(where: { $0.outfitId == outfit.outfitId }) else {
            await model.refresh(chip: model.appliedChip)
            currentID = model.outfits.first?.outfitId
            return
        }
        withAnimation { currentID = outfits[(index + 1) % outfits.count].outfitId }
    }
}

extension Wire.OutfitResponse: @retroactive Identifiable {
    public var id: String { outfitId }
}

/// The outfit as a flat-lay: every garment in a two-column arrangement sized
/// by how tall the piece is. Tapping a garment offers to swap it.
struct OutfitBoard: View {
    let items: [BoardItem]
    var onTap: ((BoardItem) -> Void)?

    private let gap: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let frames = OutfitBoardLayout.frames(for: items.map(\.role))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(items, frames)), id: \.0.id) { item, frame in
                    Button {
                        onTap?(item)
                    } label: {
                        GarmentImage(url: item.imageURL)
                    }
                    .buttonStyle(.plain)
                    .disabled(onTap == nil)
                    .frame(
                        width: max(0, proxy.size.width * frame.width - gap),
                        height: max(0, proxy.size.height * frame.height - gap)
                    )
                    .offset(x: proxy.size.width * frame.x + gap / 2, y: proxy.size.height * frame.y + gap / 2)
                    .accessibilityLabel("\(Garment.category(item.role))，\(item.name)")
                }
            }
        }
        .padding(gap)
        .aspectRatio(0.86, contentMode: .fit)
        .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.separator))
    }
}
