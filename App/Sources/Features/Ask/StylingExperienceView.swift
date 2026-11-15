import AidrobeKit
import SwiftUI

/// A visual reaction and an intention stay separate from a worn-day reflection.
struct StylingExperienceView: View {
    let outfitID: String
    var conversationID: String? = nil
    var revision: Int? = nil
    var refreshID = false
    @Environment(AppModel.self) private var app
    @State private var result: Wire.StylingExperienceListResponse?
    @State private var unavailable = false
    @State private var isSaving = false
    @State private var issue: String?
    @State private var editing = false
    @State private var feeling = "like"
    @State private var note = ""
    @State private var pendingKey: Data?
    @State private var pendingRequestID: String?
    @State private var activeOutfitID: String?
    @State private var readEpoch = 0
    private let accountGeneration = AccountLocalData.generation

    private var state: StylingExperienceState? { result.map(StylingExperienceState.init) }
    private var isCurrent: Bool {
        activeOutfitID == outfitID && accountGeneration == AccountLocalData.generation && !Task.isCancelled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            if !unavailable {
                if let state {
                    FlowLayout {
                        Chip(title: "觉得好看", isSelected: state.appreciated != nil) {
                            Task { await toggle(.appreciated, existing: state.appreciated) }
                        }
                        Chip(title: "想试试", isSelected: state.wantToTry != nil) {
                            Task { await toggle(.wantToTry, existing: state.wantToTry) }
                        }
                    }
                    .disabled(isSaving)
                    if let day = state.wornDate {
                        Text("\(Garment.day(day) ?? day)穿过之后")
                            .font(.subheadline).foregroundStyle(Color.secondaryLabel)
                        if let feedback = state.wearFeedback, !editing {
                            Text(Self.feelingTitle(feedback.feedback?.rawValue ?? "neutral"))
                            if let note = feedback.note, !note.isEmpty {
                                Text(note).font(.footnote).foregroundStyle(Color.secondaryLabel)
                            }
                            HStack(spacing: Spacing.control) {
                                Button("改一下") {
                                    feeling = feedback.feedback?.rawValue ?? "neutral"
                                    note = feedback.note ?? ""
                                    editing = true
                                }
                                Button("撤销这条感受") { Task { await remove(feedback.experienceId) } }
                            }
                            .font(.subheadline)
                            .disabled(isSaving)
                        } else {
                            reflectionEditor
                        }
                    }
                }
                if let issue {
                    Text(issue).font(.footnote).foregroundStyle(Color.secondaryLabel)
                    Button("重新读取") { Task { await load() } }
                        .font(.subheadline).disabled(isSaving)
                }
            }
        }
        .task(id: "\(outfitID)|\(refreshID)") {
            if activeOutfitID != outfitID {
                activeOutfitID = outfitID
                result = nil
                unavailable = false
                editing = false
                issue = nil
                pendingKey = nil
                pendingRequestID = nil
            }
            await load()
        }
    }

    private var reflectionEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            FlowLayout {
                ForEach(["like", "neutral", "dislike"], id: \.self) { option in
                    Chip(title: Self.feelingTitle(option), isSelected: feeling == option) { feeling = option }
                }
            }
            TextField("哪里合适，哪里想调整？（可不填）", text: $note, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .onChange(of: note) { if note.count > 500 { note = String(note.prefix(500)) } }
            Button("记下感受") { Task { await save(.wearFeedback) } }
                .buttonStyle(.glass)
        }
        .disabled(isSaving)
    }

    private static func feelingTitle(_ value: String) -> String {
        switch value {
        case "like": "挺喜欢"
        case "dislike": "不太合适"
        default: "一般"
        }
    }

    private func load() async {
        guard isCurrent else { return }
        readEpoch += 1
        let expectedRead = readEpoch
        do {
            let loaded = try await app.api.send(Endpoints.stylingExperiences(outfitID: outfitID))
            guard isCurrent, expectedRead == readEpoch else { return }
            result = loaded
            unavailable = false
            issue = nil
            if !editing {
                let feedback = StylingExperienceState(loaded).wearFeedback
                feeling = feedback?.feedback?.rawValue ?? "like"
                note = feedback?.note ?? ""
            }
        } catch {
            guard isCurrent, expectedRead == readEpoch else { return }
            if [404, 503].contains((error as? APIError)?.status ?? 0) {
                unavailable = true
            } else {
                issue = "没能读取这套的感受，可以再试一次。"
            }
        }
    }

    private func toggle(_ kind: Wire.StylingExperienceRequest.KindPayload, existing: Wire.StylingExperienceResponse?) async {
        if let existing { await remove(existing.experienceId) }
        else { await save(kind) }
    }

    private func save(_ kind: Wire.StylingExperienceRequest.KindPayload) async {
        guard !isSaving, !unavailable, let state, isCurrent else { return }
        var body = Wire.StylingExperienceRequest(requestId: "", outfitId: outfitID, kind: kind)
        if let conversationID, let revision {
            body.conversationId = conversationID
            body.revision = revision
        }
        if kind == .wearFeedback {
            guard let day = state.wornDate else { return }
            body.wornDate = day
            body.feedback = .init(rawValue: feeling)
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            body.note = trimmed.isEmpty ? nil : trimmed
            body.supersedesId = state.wearFeedback?.experienceId
        }
        isSaving = true
        readEpoch += 1
        defer { isSaving = false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let key = try encoder.encode(body)
            if pendingKey != key {
                pendingKey = key
                pendingRequestID = UUID().uuidString
            }
            body.requestId = pendingRequestID ?? UUID().uuidString
            _ = try await app.api.send(Endpoints.recordStylingExperience(body))
            guard isCurrent else { return }
            pendingKey = nil
            pendingRequestID = nil
            editing = false
            await load()
        } catch {
            guard isCurrent else { return }
            if [404, 503].contains((error as? APIError)?.status ?? 0) {
                unavailable = true
                return
            }
            if (error as? APIError)?.status == 409 {
                pendingKey = nil
                pendingRequestID = nil
                editing = false
                await load()
                guard isCurrent else { return }
                issue = "这条记录已有变化，已重新读取。"
            } else {
                issue = "没能保存，请再试一次。"
            }
        }
    }

    private func remove(_ id: String) async {
        guard !isSaving, isCurrent else { return }
        isSaving = true
        readEpoch += 1
        defer { isSaving = false }
        do {
            _ = try await app.api.send(Endpoints.removeStylingExperience(id))
            guard isCurrent else { return }
            editing = false
            await load()
        } catch {
            guard isCurrent else { return }
            if [404, 503].contains((error as? APIError)?.status ?? 0) {
                unavailable = true
                return
            }
            issue = "没能撤销，请再试一次。"
        }
    }
}
