import AidrobeKit
import Charts
import SwiftUI

/// What the wardrobe's own records say: how much of it gets worn, what is
/// worn most, what has been resting, and which colours it leans on.
struct InsightsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: InsightsModel?

    var body: some View {
        ZStack {
            if let model {
                switch model.phase {
                case .loading:
                    ProgressView()
                case let .failed(message):
                    ContentUnavailableView {
                        Label("没能读到衣橱数据", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("再试一次") { Task { await model.load() } }
                            .buttonStyle(.glass)
                    }
                case .loaded:
                    if let summary = model.summary { page(model, summary) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .navigationTitle("衣橱洞察")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = InsightsModel(api: app.api, wardrobe: app.wardrobe) }
            await model?.load()
        }
    }

    private func page(_ model: InsightsModel, _ summary: Wire.InsightsSummaryResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                figures(summary)
                if summary.hasSufficientWearHistory != true {
                    Text("穿着记录还不多，下面的判断只是个开头。每天在今日页记一次，穿几次之后这里会更准。")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                        .padding(Spacing.row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentSoft, in: .rect(cornerRadius: Radius.tile))
                }
                health(model)
                mostWorn(model)
                resting(model, thresholdDays: summary.idleThresholdDays)
                palette(model)
                costPerWear(model)
            }
            .padding(Spacing.screen)
        }
        .refreshable { await model.load() }
    }

    // MARK: Figures

    private func figures(_ summary: Wire.InsightsSummaryResponse) -> some View {
        HStack(alignment: .top, spacing: 0) {
            figure("\(summary.totalItems)", "件衣服")
            figure("\(Int((summary.activeRate * 100).rounded()))%", "近三个月穿到")
            figure("\(summary.wearHistoryCount ?? 0)", "次穿着记录")
        }
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.display(34, weight: .black, relativeTo: .largeTitle))
                .foregroundStyle(Color.label)
            Text(caption)
                .font(.caption)
                .foregroundStyle(Color.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Health

    @ViewBuilder private func health(_ model: InsightsModel) -> some View {
        if let health = model.health {
            VStack(alignment: .leading, spacing: Spacing.control) {
                SectionHeading(title: "利用程度")
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    Text("\(health.score)")
                        .font(.display(44, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    Text("/ 100")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.tertiaryLabel)
                    Spacer()
                    Text(model.healthVerdict)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                ProgressView(value: Double(min(max(health.score, 0), 100)), total: 100)
                    .tint(Color.label)
                    .accessibilityHidden(true)
                ForEach(Array(model.healthFindings.enumerated()), id: \.offset) { index, finding in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.control) {
                        Text("0\(index + 1)")
                            .font(.display(15, weight: .regular, relativeTo: .subheadline))
                            .foregroundStyle(Color.accent)
                        Text(finding)
                            .font(.body)
                            .foregroundStyle(Color.secondaryLabel)
                    }
                }
            }
        }
    }

    // MARK: Most worn

    @ViewBuilder private func mostWorn(_ model: InsightsModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "最常穿")
                .padding(.bottom, 4)
            if model.topItems.isEmpty {
                note("还没有穿着记录。记下第一套之后，这里会排出你最常穿的几件。")
            } else {
                let most = model.topItems.map(\.wearCount).max() ?? 1
                ForEach(model.topItems.prefix(5), id: \.itemId) { item in
                    itemRow(model, id: item.itemId, title: item.title, cover: item.coverImageUrl) {
                        HStack(spacing: Spacing.tight) {
                            // Share of the most-worn piece, as a plain bar.
                            Rectangle()
                                .fill(Color.label)
                                .frame(width: 64 * CGFloat(item.wearCount) / CGFloat(max(most, 1)), height: 3)
                                .frame(width: 64, alignment: .trailing)
                            Text("\(item.wearCount) 次")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Color.secondaryLabel)
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: Resting

    @ViewBuilder private func resting(_ model: InsightsModel, thresholdDays: Int) -> some View {
        if !model.idleItems.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "有阵子没穿 · \(model.idleItems.count) 件")
                    .padding(.bottom, 4)
                ForEach(model.idleItems.prefix(8), id: \.itemId) { item in
                    itemRow(model, id: item.itemId, title: item.title, cover: item.coverImageUrl) {
                        Text(Garment.day(item.lastWorn).map { "上次 \($0)" } ?? "还没穿过")
                            .font(.subheadline)
                            .foregroundStyle(Color.tertiaryLabel)
                    }
                }
                Text("超过 \(thresholdDays) 天没穿的衣服。合适的日子，今日搭配会把它们重新带出来。")
                    .font(.footnote)
                    .foregroundStyle(Color.tertiaryLabel)
                    .padding(.top, Spacing.control)
            }
        }
    }

    // MARK: Palette

    @ViewBuilder private func palette(_ model: InsightsModel) -> some View {
        if !model.colors.isEmpty {
            let total = model.colors.reduce(0) { $0 + $1.count }
            VStack(alignment: .leading, spacing: Spacing.row) {
                SectionHeading(title: "颜色")
                Chart(model.colors) { share in
                    BarMark(x: .value("件数", share.count))
                        .foregroundStyle(Garment.swatch(share.key) ?? Color.fill)
                }
                .chartXScale(domain: 0...max(total, 1))
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 28)
                .overlay(Rectangle().strokeBorder(Color.separator))
                .accessibilityLabel("衣橱颜色构成")
                FlowLayout(spacing: Spacing.row) {
                    ForEach(model.colors.prefix(8)) { share in
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(Garment.swatch(share.key) ?? Color.fill)
                                .frame(width: 10, height: 10)
                                .overlay(Rectangle().strokeBorder(Color.separator))
                            Text("\(Garment.color(share.key)) \(share.count)")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondaryLabel)
                        }
                    }
                }
            }
        }
    }

    // MARK: Cost per wear

    private func costPerWear(_ model: InsightsModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "每穿一次多少钱")
                .padding(.bottom, 4)
            if model.costs.isEmpty {
                note("给衣服记上买入价格并穿过之后，这里会算出每穿一次的花费，越常穿越划算。")
            } else {
                ForEach(model.costs.prefix(5), id: \.itemId) { item in
                    itemRow(model, id: item.itemId, title: item.title, cover: nil) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("¥\(item.costPerWear ?? "")")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(Color.label)
                            Text("穿过 \(item.wearCount) 次")
                                .font(.caption)
                                .foregroundStyle(Color.tertiaryLabel)
                        }
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Color.secondaryLabel)
            .padding(.top, Spacing.control)
    }

    /// Thumbnail, name and a trailing value; opens the garment when it is still in the wardrobe.
    @ViewBuilder
    private func itemRow(
        _ model: InsightsModel,
        id: String,
        title: String,
        cover: String?,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        let row = HStack(spacing: Spacing.control) {
            GarmentImage(url: model.imageURL(itemID: id, fallback: cover))
                .frame(width: 44, height: 55)
            Text(app.wardrobe.item(id)?.displayName ?? title)
                .font(.body)
                .foregroundStyle(Color.label)
                .lineLimit(1)
            Spacer(minLength: Spacing.tight)
            trailing()
        }
        .padding(.vertical, Spacing.tight)
        .contentShape(.rect)
        if model.isInWardrobe(id) {
            NavigationLink {
                ItemDetailView(itemID: id)
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
