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
        .overlay {
            if let sky = model?.sky { WeatherLight(visual: sky) }
        }
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
    @State private var shareDraft: OutfitShareDraft?
    @State private var generationTarget: Wire.OutfitResponse?
    @State private var showsGenerationConfirm = false
    @State private var showPieces: Set<String> = []

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
        .task(id: outfit.outfitId) { await model.loadGeneratedImage(for: outfit.outfitId) }
        .sheet(item: $swapTarget) { target in
            SwapSheet(outfit: target.outfit, slot: target.slot, model: model)
        }
        .sheet(item: $feedbackOutfit) { outfit in
            FeedbackSheet(outfit: outfit, model: model)
        }
        .sheet(isPresented: $showsContext) {
            ContextSheet(model: model)
        }
        .sheet(item: $shareDraft) { draft in
            OutfitShareSheet(draft: draft)
        }
        .confirmationDialog("生成整套搭配图", isPresented: $showsGenerationConfirm, presenting: generationTarget) { outfit in
            Button("生成") { Task { await model.generateImage(for: outfit) } }
        } message: { _ in
            Text("会把这套搭配的衣物参考图发送给 OpenAI。生成图里的颜色和细节可能有变化。")
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
                    let items = model.boardItems(for: outfit)
                    let hasSwaps = items.contains(where: \.isSwapped)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        outfitPreview(outfit, items: items, hasSwaps: hasSwaps)
                            .overlay(alignment: .topTrailing) {
                                HStack(spacing: 0) {
                                    Button {
                                        shareDraft = OutfitShareDraft(
                                            items: items,
                                            date: Garment.day(model.today?.recommendationDate)
                                        )
                                    } label: {
                                        Image(systemName: "square.and.arrow.up")
                                            .foregroundStyle(Color.secondaryLabel)
                                            .frame(width: 44, height: 44)
                                            .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("分享这套")
                                    favoriteButton(outfit)
                                }
                            }

                        if model.rejectedOutfitImages.contains(outfit.outfitId) && !hasSwaps {
                            Text("整套图未通过核对")
                                .font(.footnote)
                                .foregroundStyle(Color.secondaryLabel)
                        } else if !hasSwaps {
                            let previewIsOpen = showPieces.contains(outfit.outfitId)
                            Button(previewIsOpen ? "返回整套搭配图" : "看单品拼图") {
                                if !showPieces.insert(outfit.outfitId).inserted {
                                    showPieces.remove(outfit.outfitId)
                                }
                            }
                            .font(.footnote)
                        }
                    }
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

    @ViewBuilder
    private func outfitPreview(_ outfit: Wire.OutfitResponse, items: [BoardItem], hasSwaps: Bool) -> some View {
        if hasSwaps || showPieces.contains(outfit.outfitId) || model.rejectedOutfitImages.contains(outfit.outfitId) {
            OutfitBoard(items: items) { slot in
                swapTarget = SwapTarget(outfit: outfit, slot: slot)
            }
        } else if let image = model.generatedImages[outfit.outfitId] {
            GarmentImage(url: image, forceOriginal: true, fit: true, photoAspectRatio: 2.0 / 3.0)
                .accessibilityHidden(false)
                .accessibilityLabel("AI 生成的整套搭配图")
        } else {
            Color.elevatedBackground
                .aspectRatio(0.86, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Radius.card))
                .overlay {
                    if model.generatingOutfits.contains(outfit.outfitId) {
                        ProgressView("正在准备整套搭配图…")
                            .font(.footnote)
                    } else {
                        Button("生成整套搭配图", systemImage: "sparkles") {
                            generationTarget = outfit
                            showsGenerationConfirm = true
                        }
                        .buttonStyle(.glass)
                    }
                }
        }
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
        let reasoning = outfit.reasoning ?? []
        // What the user told us earlier and how it changed this outfit comes
        // first and reads differently: it is the app keeping its promise.
        let remembered = reasoning.filter { $0._type == "feedback" }
        let others = reasoning.filter { $0._type != "feedback" }.prefix(3)
        if !reasoning.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.control) {
                SectionHeading(title: "为什么是这套")
                ForEach(Array(remembered.enumerated()), id: \.offset) { _, reason in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("记得你说过")
                            .font(.caption.weight(.medium))
                            .kerning(1.5)
                            .foregroundStyle(Color.accent)
                        Text(reason.text)
                            .font(.body)
                            .foregroundStyle(Color.label)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.row)
                    .background(Color.accentSoft, in: .rect(cornerRadius: Radius.tile))
                }
                ForEach(Array(others.enumerated()), id: \.offset) { index, reason in
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
    var pictures: [String: GarmentRender]?
    var onTap: ((BoardItem) -> Void)?

    private let gap: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let frames = OutfitBoardLayout.frames(for: items.map(\.role))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    tile(item, in: rect(frames[index], in: proxy.size))
                }
            }
        }
        .padding(gap)
        .aspectRatio(0.86, contentMode: .fit)
        .background(Color.elevatedBackground, in: .rect(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.separator))
    }

    /// A unit-square frame scaled to the board, inset by half the gap on every side.
    private func rect(_ frame: OutfitBoardLayout.Frame, in size: CGSize) -> CGRect {
        let x: CGFloat = size.width * frame.x + gap / 2
        let y: CGFloat = size.height * frame.y + gap / 2
        let width: CGFloat = max(0, size.width * frame.width - gap)
        let height: CGFloat = max(0, size.height * frame.height - gap)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func tile(_ item: BoardItem, in rect: CGRect) -> some View {
        Group {
            if let onTap {
                Button {
                    onTap(item)
                } label: {
                    GarmentImage(url: item.imageURL, forceOriginal: item.usesGeneratedCover)
                }
                .buttonStyle(.plain)
            } else if let pictures {
                GarmentPicture(render: pictures[item.id])
            } else {
                GarmentImage(url: item.imageURL, forceOriginal: item.usesGeneratedCover)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .accessibilityLabel("\(Garment.category(item.role))，\(item.name)")
    }
}
