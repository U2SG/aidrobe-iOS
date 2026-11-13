import AidrobeKit
import SwiftUI

/// P0 connectivity screen: fetches `/v1/recommendations/today` as raw JSON to prove
/// the API facade end to end. Replaced by the real Today V2 surface in P1.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState = .idle

    enum LoadState {
        case idle, loading
        case loaded(JSONValue)
        case failed(String)
    }

    var body: some View {
        List {
            Section("后端") {
                LabeledContent("地址", value: model.environment.apiBaseURL.absoluteString)
                LabeledContent("环境", value: model.environment.stage.rawValue)
            }
            Section("今日推荐（原始数据）") {
                switch state {
                case .idle, .loading:
                    ProgressView()
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.danger)
                case let .loaded(json):
                    let outfits = json["outfits"]?.arrayValue ?? []
                    LabeledContent("搭配数", value: "\(outfits.count)")
                    LabeledContent("状态", value: json["status"]?.stringValue ?? "—")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.background)
        .navigationTitle("今日")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let json = try await model.api.send(
                Endpoint<JSONValue>(.get, "/v1/recommendations/today", timeout: Endpoint<JSONValue>.slowTimeout)
            )
            state = .loaded(json)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
