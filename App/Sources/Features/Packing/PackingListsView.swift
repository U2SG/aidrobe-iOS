import AidrobeKit
import SwiftUI

/// Trips: what to bring from your own wardrobe, and what is already in the bag.
struct PackingListsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: PackingModel?
    @State private var isCreating = false
    @State private var opened: String?

    var body: some View {
        // ZStack, not Group: the task that creates the model must attach to something.
        ZStack {
            if let model {
                switch model.phase {
                case .loading:
                    ProgressView()
                case .unavailable:
                    ContentUnavailableView(
                        "暂时用不了", systemImage: "suitcase", description: Text("出行打包现在没有开放，晚些时候再来。")
                    )
                case let .failed(message):
                    ContentUnavailableView {
                        Label("没能打开打包清单", systemImage: "wifi.exclamationmark")
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
        .navigationTitle("出行打包")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model?.phase == .loaded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新的行程", systemImage: "plus") { isCreating = true }
                }
            }
        }
        .navigationDestination(item: $opened) { id in
            if let model { PackingListDetailView(listID: id, model: model) }
        }
        .sheet(isPresented: $isCreating) {
            if let model {
                NewTripSheet(model: model) { opened = $0 }
            }
        }
        .toast(Binding(get: { model?.notice }, set: { model?.notice = $0 }))
        .task {
            if model == nil { model = PackingModel(api: app.api) }
            async let wardrobe: Void = app.wardrobe.items.isEmpty ? app.wardrobe.load() : ()
            await model?.load()
            await wardrobe
        }
    }

    private func page(_ model: PackingModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Text("出行").kicker()
                    Text("出门几天，带什么")
                        .font(.display(30, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    Text("说一下去哪、去几天，从你的衣橱里排出每天的搭配，尽量一件多穿、少带几件。")
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if model.lists.isEmpty {
                    Button {
                        isCreating = true
                    } label: {
                        Text("排一趟行程").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeading(title: "行程")
                            .padding(.bottom, 4)
                        ForEach(model.lists, id: \.packingListId) { list in
                            Button {
                                opened = list.packingListId
                            } label: {
                                TripRow(list: list)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Color.separator)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .refreshable { await model.load() }
    }
}

private struct TripRow: View {
    let list: Wire.PackingListResponse

    var body: some View {
        let pieces = list.pieces
        let packed = pieces.count { $0.isPacked }
        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PackingCopy.title(list))
                    .font(.display(20, relativeTo: .title3))
                    .foregroundStyle(Color.label)
                Text(PackingCopy.summary(list))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }
            Spacer(minLength: Spacing.tight)
            if !pieces.isEmpty {
                Text(packed == pieces.count ? "装好了" : "\(packed) / \(pieces.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(packed == pieces.count ? Color.success : Color.tertiaryLabel)
            }
        }
        .padding(.vertical, Spacing.control)
        .frame(minHeight: 64)
        .contentShape(.rect)
    }
}

/// Where, how long, and what for. The backend builds the list on create.
private struct NewTripSheet: View {
    let model: PackingModel
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var days = 3
    @State private var hasDate = false
    @State private var departure = Date.now
    @State private var scenes: Set<String> = ["casual"]
    @State private var weather = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("去哪里（可以不填）", text: $destination)
                    Stepper("去 \(days) 天", value: $days, in: 1...14)
                    Toggle("定了出发日期", isOn: $hasDate.animation())
                    if hasDate {
                        DatePicker("出发", selection: $departure, in: Date.now..., displayedComponents: .date)
                    }
                }
                Section {
                    FlowLayout {
                        ForEach(PackingCopy.scenes, id: \.key) { scene in
                            Chip(title: scene.title, isSelected: scenes.contains(scene.key)) {
                                scenes.formSymmetricDifference([scene.key])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("会有哪些场合")
                } footer: {
                    Text("每天轮流按这些场合来搭。")
                }
                Section("那边的天气") {
                    TextField("比如：冷、有雨（可以不填）", text: $weather)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.groupedBackground)
            .navigationTitle("新的行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isCreating {
                        ProgressView()
                    } else {
                        Button("排出来") {
                            Task {
                                let id = await model.create(
                                    destination: destination,
                                    days: days,
                                    departure: hasDate ? departure : nil,
                                    scenes: PackingCopy.scenes.map(\.key).filter(scenes.contains),
                                    weather: weather
                                )
                                if let id {
                                    dismiss()
                                    onCreated(id)
                                }
                            }
                        }
                        .disabled(scenes.isEmpty)
                    }
                }
            }
            .toast(Binding(get: { model.notice }, set: { model.notice = $0 }))
        }
        .presentationDetents([.large])
    }
}
