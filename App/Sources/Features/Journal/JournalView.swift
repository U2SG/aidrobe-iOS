import AidrobeKit
import SwiftUI

/// The wear journal: a month at a glance, then every recorded outfit, newest first.
struct JournalView: View {
    @Environment(AppModel.self) private var app
    @State private var model: JournalModel?
    @State private var opened: Wire.OutfitHistoryEntry?

    var body: some View {
        // ZStack, not Group: the task that creates the model must attach to something.
        ZStack {
            if let model {
                switch model.phase {
                case .loading:
                    ProgressView()
                case let .failed(message):
                    ContentUnavailableView {
                        Label("没能打开日记", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("再试一次") { Task { await model.load() } }
                            .buttonStyle(.glass)
                    }
                case .loaded:
                    page(model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .navigationTitle("穿搭日记")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { entry in
            if let model { OutfitRecordView(entry: entry, model: model) }
        }
        .toast(Binding(get: { model?.notice }, set: { model?.notice = $0 }))
        .task {
            if model == nil { model = JournalModel(api: app.api, wardrobe: app.wardrobe) }
            await model?.load()
        }
    }

    private func page(_ model: JournalModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.section) {
                MonthCalendar(model: model) { day in
                    Task { opened = await model.entry(on: day) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: model.total == 0 ? "记录" : "记录 · \(model.total) 天")
                        .padding(.bottom, 4)
                    if model.entries.isEmpty {
                        Text("还没有记录。在今日页点「就穿这套」，这里会一天天记下来，之后能回头看哪天穿了什么、感觉怎么样。")
                            .font(.body)
                            .foregroundStyle(Color.secondaryLabel)
                            .padding(.top, Spacing.control)
                    }
                    ForEach(model.entries, id: \.wearHistoryId) { entry in
                        Button {
                            opened = entry
                        } label: {
                            JournalRow(entry: entry, model: model)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.separator)
                    }
                    if model.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.row)
                            .task { await model.loadMore() }
                    }
                }
            }
            .padding(Spacing.screen)
        }
        .refreshable { await model.load() }
    }
}

/// One month, Monday first. Days with a record carry a mark and open that day.
private struct MonthCalendar: View {
    let model: JournalModel
    let open: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        let month = model.month
        let marked = model.markedDays[month] ?? []
        VStack(alignment: .leading, spacing: Spacing.row) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(month.title)
                        .font(.display(28, weight: .black, relativeTo: .title))
                        .foregroundStyle(Color.label)
                    Text(marked.isEmpty ? "这个月还没有记录" : "记了 \(marked.count) 天")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                Spacer()
                stepper(month)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdays, id: \.self) { name in
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(Color.tertiaryLabel)
                        .frame(height: 24)
                }
                ForEach(0..<month.leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 44)
                }
                ForEach(1...month.numberOfDays, id: \.self) { day in
                    DayCell(day: day, key: month.key(day: day), isMarked: marked.contains(month.key(day: day)), open: open)
                }
            }
        }
        .task(id: month) { await model.loadMarks() }
    }

    private func stepper(_ month: JournalMonth) -> some View {
        HStack(spacing: Spacing.tight) {
            Button {
                model.month = month.shifted(by: -1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 20, height: 20)
            }
            .accessibilityLabel("上个月")
            Button {
                model.month = month.shifted(by: 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 20, height: 20)
            }
            .disabled(month == .current)
            .accessibilityLabel("下个月")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

private struct DayCell: View {
    let day: Int
    let key: String
    let isMarked: Bool
    let open: (String) -> Void

    var body: some View {
        let isToday = key == JournalDay.today
        Button {
            open(key)
        } label: {
            VStack(spacing: 3) {
                Text("\(day)")
                    .font(.callout.monospacedDigit().weight(isMarked ? .semibold : .regular))
                    .foregroundStyle(isMarked ? Color.label : Color.tertiaryLabel)
                Circle()
                    .fill(isMarked ? Color.accent : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.separator)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isMarked)
        .accessibilityLabel(isMarked ? "\(day)日，有记录" : "\(day)日")
    }
}

private struct JournalRow: View {
    let entry: Wire.OutfitHistoryEntry
    let model: JournalModel

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.row) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayNumber)
                    .font(.display(28, weight: .black, relativeTo: .title))
                    .foregroundStyle(Color.label)
                Text(JournalDay.weekday(entry.wornDate))
                    .font(.caption)
                    .foregroundStyle(Color.tertiaryLabel)
            }
            .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.outfit?.title ?? "自己搭的一套")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.label)
                    Spacer(minLength: Spacing.tight)
                    if let feeling = JournalModel.feeling(entry.feedbackType) {
                        Text(feeling)
                            .font(.subheadline)
                            .foregroundStyle(Color.tertiaryLabel)
                    }
                }
                if let items = model.boardItems(for: entry), !items.isEmpty {
                    HStack(spacing: Spacing.tight) {
                        ForEach(items.prefix(5)) { item in
                            GarmentImage(url: item.imageURL)
                                .frame(width: 44, height: 55)
                        }
                    }
                } else if entry.outfit != nil {
                    // Keeps the row from jumping when the pieces arrive.
                    Color.clear.frame(height: 55)
                }
            }
        }
        .padding(.vertical, Spacing.row)
        .contentShape(.rect)
        .task { await model.loadOutfit(for: entry) }
        .accessibilityElement(children: .combine)
    }

    private var dayNumber: String {
        guard let parts = JournalDay.parts(entry.wornDate) else { return "" }
        // Entries from other months say so, since the list runs across months.
        return parts.month == model.month.month && parts.year == model.month.year
            ? "\(parts.day)" : "\(parts.month).\(parts.day)"
    }
}
