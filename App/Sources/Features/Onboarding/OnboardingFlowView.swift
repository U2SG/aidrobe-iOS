import AidrobeKit
import SwiftUI

/// First run, between Welcome and the tabs: put in a few clothes, say where
/// and when you head out, see the first outfit. Every step can be skipped;
/// the caller decides what finishing means.
struct OnboardingFlowView: View {
    let onFinish: () -> Void
    @State private var step = Step.clothes

    enum Step: Int, CaseIterable {
        case clothes, routine, firstOutfit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.tertiaryLabel)
                Spacer()
                Button(step == .firstOutfit ? "直接进入" : "跳过") { advance() }
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                    .frame(minHeight: 44)
            }
            Group {
                switch step {
                case .clothes: ClothesStep(next: advance)
                case .routine: RoutineStep(next: advance)
                case .firstOutfit: FirstOutfitStep(addClothes: { step = .clothes }, finish: onFinish)
                }
            }
            .transition(.opacity)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.bottom, Spacing.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.background)
        .animation(.default, value: step)
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next } else { onFinish() }
    }
}

/// The statement every step opens with, in Welcome's voice.
private struct StepHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            Text(title)
                .font(.display(34, weight: .black, relativeTo: .largeTitle))
                .foregroundStyle(Color.label)
            Text(detail)
                .font(.body)
                .foregroundStyle(Color.secondaryLabel)
        }
        .padding(.top, Spacing.section)
    }
}

// MARK: 1 · Clothes

private struct ClothesStep: View {
    let next: () -> Void
    @Environment(AppModel.self) private var app
    @State private var isImporting = false

    /// What one outfit needs. A dress stands in for top and bottom.
    private var slots: [(title: String, count: Int)] {
        let items = app.wardrobe.items
        let dresses = items.count { $0.category == "dress" }
        return [
            ("上装", items.count { $0.category == "top" } + dresses),
            ("下装", items.count { $0.category == "bottom" } + dresses),
            ("鞋", items.count { $0.category == "shoes" }),
        ]
    }

    private var isEnough: Bool { slots.allSatisfy { $0.count > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "先放进几件常穿的",
                detail: "一件上装、一件下装、一双鞋，就能搭出第一套。平铺或挂着拍，一张照片一件。"
            )
            Spacer(minLength: Spacing.section)
            VStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                    Divider().overlay(Color.separator)
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                        Text("0\(index + 1)")
                            .font(.display(17, weight: .regular, relativeTo: .body))
                            .foregroundStyle(Color.accent)
                        Text(slot.title)
                            .font(.headline)
                            .foregroundStyle(Color.label)
                        Spacer()
                        Text(slot.count > 0 ? "有了" : "还缺")
                            .font(.subheadline)
                            .foregroundStyle(slot.count > 0 ? Color.success : Color.tertiaryLabel)
                    }
                    .padding(.vertical, Spacing.row)
                }
                Divider().overlay(Color.separator)
            }
            if !app.wardrobe.items.isEmpty {
                Text("衣橱里现在有 \(app.wardrobe.items.count) 件")
                    .font(.footnote)
                    .foregroundStyle(Color.tertiaryLabel)
                    .padding(.top, Spacing.control)
            }
            Spacer(minLength: Spacing.section)
            VStack(spacing: Spacing.control) {
                if isEnough {
                    Button(action: next) {
                        Text("下一步").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        isImporting = true
                    } label: {
                        Text("再添几件").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else {
                    Button {
                        isImporting = true
                    } label: {
                        Text("添加衣物").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.large)
        }
        .sheet(isPresented: $isImporting) {
            ImportFlowView { Task { await app.wardrobe.load() } }
        }
        .task { await app.wardrobe.load() }
    }
}

// MARK: 2 · Where and when

private struct RoutineStep: View {
    let next: () -> Void
    @Environment(AppModel.self) private var app
    @AppStorage(AccountLocalData.placeNameKey) private var placeName = ""
    @State private var model: ProfileModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "你在哪，几点出门",
                detail: "城市决定天气，出门时间决定按哪个时段的温度来搭。之后都能在「我的」里改。"
            )
            Spacer(minLength: Spacing.section)
            if let model {
                VStack(spacing: 0) {
                    Divider().overlay(Color.separator)
                    FactRow(title: "所在城市") {
                        if model.isLocating {
                            ProgressView()
                        } else {
                            Button(model.settings?.location == nil ? "用当前位置" : (placeName.isEmpty ? "已设置" : placeName)) {
                                Task {
                                    let generation = AccountLocalData.generation
                                    if let place = await model.useCurrentLocation(),
                                       generation == AccountLocalData.generation { placeName = place }
                                }
                            }
                            .foregroundStyle(model.settings?.location == nil ? Color.accent : Color.label)
                            .frame(minHeight: 44)
                        }
                    }
                    FactRow(title: "出门时间") {
                        DatePicker(
                            "出门时间",
                            selection: Binding(
                                get: { model.departure },
                                set: { time in Task { await model.setDeparture(time) } }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                    }
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Color.danger)
                        .padding(.top, Spacing.control)
                }
            }
            Spacer(minLength: Spacing.section)
            Button(action: next) {
                Text("下一步").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .task {
            if model == nil { model = ProfileModel(api: app.api) }
            await model?.load()
        }
    }
}

// MARK: 3 · First outfit

private struct FirstOutfitStep: View {
    let addClothes: () -> Void
    let finish: () -> Void
    @Environment(AppModel.self) private var app
    @State private var gate: Wire.FirstOutfitGateResponse?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let outfit = gate?.firstOutfit {
                StepHeading(title: "这是你的第一套", detail: outfit.reason)
                Spacer(minLength: Spacing.row)
                OutfitBoard(items: boardItems(outfit))
                Spacer(minLength: Spacing.row)
                Button(action: finish) {
                    Text("开始用").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else if let gate {
                StepHeading(title: "还差一点", detail: missingText(gate))
                Spacer(minLength: Spacing.section)
                VStack(spacing: Spacing.control) {
                    Button(action: addClothes) {
                        Text("回去添加").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button(action: finish) {
                        Text("先进去看看").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            } else if let failure {
                StepHeading(title: "没能搭出来", detail: failure)
                Spacer(minLength: Spacing.section)
                VStack(spacing: Spacing.control) {
                    Button {
                        Task { await load() }
                    } label: {
                        Text("再试一次").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button(action: finish) {
                        Text("先进去看看").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            } else {
                StepHeading(title: "正在搭第一套", detail: "只用你刚放进来的衣服。")
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .task { await load() }
    }

    private func load() async {
        failure = nil
        do {
            async let wardrobe: Void = app.wardrobe.load()
            let gate = try await app.api.send(Endpoints.firstOutfit())
            await wardrobe
            self.gate = gate
        } catch {
            failure = userMessage(for: error)
        }
    }

    private func boardItems(_ outfit: Wire.OutfitResponse) -> [BoardItem] {
        outfit.items.map { slot in
            let item = app.wardrobe.item(slot.itemId)
            return BoardItem(
                slotID: slot.itemId,
                itemID: slot.itemId,
                role: item?.category ?? slot.category ?? "accessory",
                name: item?.displayName ?? slot.title ?? "单品",
                imageURL: item.flatMap(WardrobeStore.imageURL)
            )
        }
    }

    /// Names what is missing; when every kind is there but nothing wearable
    /// combines (`engine_insufficient`), says that instead of guessing.
    private func missingText(_ gate: Wire.FirstOutfitGateResponse) -> String {
        if gate.missingSlots.isEmpty {
            return "衣服的种类够了，但现在能穿的还凑不成一套。再放进一两件，或把待洗的标回可以穿。"
        }
        let names = gate.missingSlots.map { Garment.category($0) }.joined(separator: "、")
        return "还缺\(names)，补上就能搭出第一套。"
    }
}
