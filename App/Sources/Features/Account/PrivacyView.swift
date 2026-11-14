import AidrobeKit
import SwiftUI

/// What is stored, where photos are processed, and the three things a user
/// can always do with their data: take it, clear it, close the account.
struct PrivacyView: View {
    @Environment(AppModel.self) private var app
    @State private var export = ExportPhase.idle
    @State private var confirmsClear = false
    @State private var confirmsDelete = false
    @State private var isWorking = false
    @State private var notice: String?

    enum ExportPhase: Equatable {
        case idle, preparing
        case ready(URL)
        case failed(String)
    }

    private let facts = [
        ("衣物照片", "原图存在你的账号下，不会被替换或重画。"),
        ("去背景", "在手机上完成，照片不会为此上传。"),
        ("穿着与反馈", "只用来给你搭配，记住了什么都能在「记住的偏好」里看到。"),
        ("位置", "只取到城市一级，用来查天气。"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("数据与隐私")
                        .font(.display(34, weight: .black, relativeTo: .largeTitle))
                        .foregroundStyle(Color.label)
                    Text("衣橱是你的。存了什么、怎么用，都写在这里。")
                        .font(.body)
                        .foregroundStyle(Color.secondaryLabel)
                }
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: "存了什么")
                    ForEach(facts, id: \.0) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.0)
                                .font(.headline)
                                .foregroundStyle(Color.label)
                            Text(fact.1)
                                .font(.subheadline)
                                .foregroundStyle(Color.secondaryLabel)
                        }
                        .padding(.vertical, Spacing.control)
                        Divider().overlay(Color.separator)
                    }
                }
                exportSection
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: "清除")
                    action(
                        "清空衣橱和记录",
                        "衣物、穿着记录和学到的偏好全部删除，账号保留。"
                    ) { confirmsClear = true }
                    action(
                        "注销账号",
                        "账号立即停用并退出登录，数据在宽限期后彻底删除。"
                    ) { confirmsDelete = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.screen)
        }
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .toast($notice)
        .disabled(isWorking)
        .confirmationDialog("清空衣橱和记录？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("全部清空", role: .destructive) { clearData() }
        } message: {
            Text("所有衣物和照片、穿着记录、反馈和学到的偏好都会删除，无法恢复。账号和登录不受影响。")
        }
        .confirmationDialog("注销账号？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("注销账号", role: .destructive) { deleteAccount() }
        } message: {
            Text("账号会立即停用并退出登录。衣橱、照片、穿着记录和偏好在宽限期结束后彻底删除，之后无法找回。")
        }
    }

    // MARK: Export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            SectionHeading(title: "带走")
            Text("把衣物、穿着记录和偏好打包成一份文件。")
                .font(.subheadline)
                .foregroundStyle(Color.secondaryLabel)
            switch export {
            case .idle:
                Button("导出我的数据") { Task { await runExport() } }
                    .buttonStyle(.glass)
            case .preparing:
                HStack(spacing: Spacing.tight) {
                    ProgressView()
                    Text("正在整理，通常不到一分钟")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                .frame(minHeight: 44)
            case let .ready(url):
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ShareLink(item: url) {
                        Label("保存或分享导出文件", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glassProminent)
                    Text("链接短时间内有效，过期后重新导出即可。")
                        .font(.footnote)
                        .foregroundStyle(Color.tertiaryLabel)
                }
            case let .failed(message):
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color.danger)
                    Button("重新导出") { Task { await runExport() } }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    /// Request, then poll every 2 s for up to 2 min.
    private func runExport() async {
        export = .preparing
        do {
            var job = try await app.api.send(Endpoints.requestDataExport())
            for _ in 0..<60 {
                if let url = job.downloadUrl.flatMap(URL.init(string:)) {
                    export = .ready(url)
                    return
                }
                if ["failed", "dead"].contains(job.status) {
                    export = .failed("这次没导出成功")
                    return
                }
                if job.status == "succeeded" {
                    // Finished without a file to hand over: say so rather than spin.
                    export = .failed("导出完成了，但没有拿到文件")
                    return
                }
                try await Task.sleep(for: .seconds(2))
                job = try await app.api.send(Endpoints.dataExport(job.jobId))
            }
            export = .failed("还在整理，稍后再来看")
        } catch is CancellationError {
            export = .idle
        } catch {
            export = .failed(userMessage(for: error))
        }
    }

    // MARK: Destructive

    private func action(_ title: String, _ detail: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: perform) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(Color.danger)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.control)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Divider().overlay(Color.separator)
        }
    }

    private func clearData() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await app.api.send(Endpoints.clearAllData())
                await app.wardrobe.load()
                notice = "已清空"
            } catch {
                notice = userMessage(for: error)
            }
        }
    }

    private func deleteAccount() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await app.api.send(Endpoints.deactivateAccount())
                app.signOut()
            } catch {
                notice = userMessage(for: error)
            }
        }
    }
}
