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
        .task {
            if model == nil { model = AskModel(api: app.api, wardrobe: app.wardrobe) }
            await model?.load()
        }
    }

    private func page(_ model: AskModel) -> some View {
        @Bindable var model = model
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    header(model)
                    ForEach(model.entries) { entry in
                        AskEntryView(entry: entry, model: model).id(entry.id)
                    }
                    if model.entries.isEmpty { opening(model) }
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
    }

    private func header(_ model: AskModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("问问").kicker()
            HStack(alignment: .bottom) {
                Text(model.entries.isEmpty ? "想问衣橱什么？" : "接着问")
                    .font(.display(34, weight: .black, relativeTo: .largeTitle))
                    .foregroundStyle(Color.label)
                Spacer()
                if !model.entries.isEmpty {
                    Button {
                        Task { await model.startOver() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(model.isAsking)
                    .accessibilityLabel("新对话")
                }
            }
            if model.entries.isEmpty {
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
                        model.reopen(item)
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
        GlassEffectContainer(spacing: Spacing.tight) {
            HStack(alignment: .bottom, spacing: Spacing.tight) {
                TextField("问一个穿搭问题", text: $draft, axis: .vertical)
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
                        if model.isAsking {
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
                .disabled(model.isAsking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.bottom, Spacing.tight)
    }

    private func send(_ question: String, _ model: AskModel) {
        guard !model.isAsking else { return }
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
                if !garments.isEmpty { garmentRow(garments) }
                feedback
            case .unavailable:
                note("问问暂时还答不了。开通后，这里会用你衣橱里的衣服来回答。")
            case let .failed(message):
                note(message)
                Button("再问一次") { Task { await model.retry(entry) } }
                    .buttonStyle(.glass)
            }
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
