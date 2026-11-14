import AidrobeKit
import SwiftUI

/// What the app has learned about the user, in sentences they can check.
/// Anything here can be removed or marked wrong; nothing is learned that
/// does not show up here.
struct MemoryView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [Wire.MemoryItemResponse]?
    @State private var failure: String?
    @State private var confirmsClear = false
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("记住的偏好")
                        .font(.display(34, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    Text("这些是从你的反馈和穿着里学到的，不是你填的表。不准的，随时划掉。")
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if let items {
                    if items.isEmpty {
                        empty
                    } else {
                        section("会避开", items.filter { $0.polarity == "negative" })
                        section("会多选", items.filter { $0.polarity != "negative" })
                        Button("全部忘掉", role: .destructive) { confirmsClear = true }
                            .frame(minHeight: 44)
                    }
                } else if let failure {
                    VStack(alignment: .leading, spacing: Spacing.control) {
                        Text(failure).foregroundStyle(Color.secondaryLabel)
                        Button("再试一次") { Task { await load() } }
                            .buttonStyle(.glass)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .toast($notice)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("全部忘掉？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("全部忘掉", role: .destructive) {
                perform("都忘掉了，搭配会从头学起") {
                    _ = try await app.api.send(Endpoints.forgetAllMemory())
                    items = []
                }
            }
        } message: {
            Text("学到的偏好会全部清除，搭配从头学起。衣物和穿着记录不受影响。")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.separator)
            ForEach(Array([
                "你说过「偏热」「太正式」这类感受后，这里会出现对应的一条。",
                "每一条都写明从哪来，可以删除，也可以标成不准。",
                "不在这里的，就是还没记住。",
            ].enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                    Text("0\(index + 1)")
                        .font(.display(17, weight: .regular, relativeTo: .body))
                        .foregroundStyle(Color.accent)
                    Text(line)
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                }
                .padding(.vertical, Spacing.row)
                Divider().overlay(Color.separator)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ entries: [Wire.MemoryItemResponse]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: title)
                    .padding(.bottom, 4)
                ForEach(entries, id: \.id) { entry in
                    HStack(alignment: .center, spacing: Spacing.row) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MemoryCopy.sentence(for: entry))
                                .font(.body)
                                .foregroundStyle(Color.label)
                            Text(MemoryCopy.provenance(for: entry))
                                .font(.caption)
                                .foregroundStyle(Color.tertiaryLabel)
                        }
                        Spacer(minLength: Spacing.tight)
                        Menu {
                            Button("这条不准", systemImage: "xmark.circle") {
                                perform("记下了，这条不再作数") {
                                    _ = try await app.api.send(Endpoints.markMemoryWrong(entry.id))
                                    items?.removeAll { $0.id == entry.id }
                                }
                            }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                perform("删掉了") {
                                    _ = try await app.api.send(Endpoints.forgetMemory(entry.id))
                                    items?.removeAll { $0.id == entry.id }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(Color.tertiaryLabel)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("处理这条")
                    }
                    .padding(.vertical, Spacing.tight)
                    Divider().overlay(Color.separator)
                }
            }
        }
    }

    private func load() async {
        do {
            items = try await app.api.send(Endpoints.memory()).preferences
            failure = nil
        } catch {
            if items == nil { failure = userMessage(for: error) }
        }
    }

    private func perform(_ success: String, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                notice = success
            } catch {
                notice = userMessage(for: error)
            }
        }
    }
}

enum MemoryCopy {
    /// The backend writes each preference as a sentence.
    static func sentence(for item: Wire.MemoryItemResponse) -> String {
        item.displayText
    }

    /// "来自你的反馈 · 初步 · 11月13日"
    static func provenance(for item: Wire.MemoryItemResponse) -> String {
        let source = switch item.source {
        case "explicit": "你告诉过衣然"
        case "feedback": "来自你的反馈"
        default: "从穿着习惯推断"
        }
        let confidence = switch item.confidence {
        case "high": "确定"
        case "medium": "较确定"
        default: "初步"
        }
        return [source, confidence, Garment.day(String(item.createdAt.prefix(10)))].compactMap(\.self).joined(separator: " · ")
    }
}
