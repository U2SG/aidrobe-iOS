import AidrobeKit
import SwiftUI

/// Scan one album of the user's own outfit photos and add what they wear, one
/// entry per garment however many photos it appears in. Pushed from the
/// add-garment sheet.
struct AlbumScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var model: AlbumScanModel?
    /// Called when the wardrobe changed.
    var onImported: () -> Void = {}

    var body: some View {
        ZStack {
            Color.groupedBackground.ignoresSafeArea()
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("扫描相册")
        .navigationBarTitleDisplayMode(.inline)
        .toast(Binding(get: { model?.notice }, set: { model?.notice = $0 }))
        .task {
            if model == nil {
                let created = AlbumScanModel(api: app.api)
                model = created
                await created.start()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: AlbumScanModel) -> some View {
        switch model.phase {
        case .starting:
            ProgressView()
        case let .noAccess(limited):
            noAccess(limited: limited)
        case .notice:
            notice(model)
        case let .albums(albums):
            albumList(albums, model: model)
        case let .ready(unseen):
            ready(unseen: unseen, model: model)
        case let .screening(done, total):
            progress("正在手机上筛选 \(done)/\(total)", detail: "截图、视频、重复和多人的照片不会上传。")
        case let .uploading(done, total):
            progress("上传中 \(done)/\(total)", detail: model.ledger.lastTally.summary)
        case .nothingToSend:
            List {
                Section {
                    Text("这次没有需要识别的照片").foregroundStyle(Color.label)
                }
                SkipSummarySection(model: model)
            }
            .scrollContentBackground(.hidden)
        case let .recognising(batch):
            recognising(batch, model: model)
        case let .review(batch), let .saving(batch):
            AlbumScanResultsView(model: model, batch: batch, onImported: onImported)
        case let .finished(added, wears):
            finished(added: added, wears: wears)
        case let .failed(message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } actions: {
                Button("重新扫描") { Task { await model.scan() } }
            }
        }
    }

    private func noAccess(limited: Bool) -> some View {
        ContentUnavailableView {
            Label(limited ? "需要访问全部照片" : "没有相册权限", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text(limited
                ? "现在只能看到你挑过的几张照片，找不到要扫描的相册。在设置里把照片权限改成「完全访问」后再来。"
                : "扫描相册需要读取照片。在设置里允许衣然访问「完全访问」的照片后再来。")
        } actions: {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func notice(_ model: AlbumScanModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.row) {
                Text("先选一个只有你的相册")
                    .font(.display(26))
                    .foregroundStyle(Color.label)
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Text("扫描只识别照片里的衣物，不会分辨照片里是谁。")
                    Text("请选一个只放你自己穿搭照的相册，可以先在系统相册里新建一个「我的穿搭」。")
                    Text("合影、朋友的照片里的衣服也会被识别出来。")
                }
                .font(.body)
                .foregroundStyle(Color.label)
                SectionHeading(title: "在手机上先筛一遍")
                Text("截图、视频、太小的图、重复的连拍和多人照片，在手机上就跳过，不会上传。每次最多看最新的 \(AlbumScan.photosPerRun) 张。")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                Button {
                    model.acceptNotice()
                } label: {
                    Text("知道了，去选相册").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, Spacing.control)
            }
            .padding(Spacing.screen)
        }
    }

    private func albumList(_ albums: [AlbumInfo], model: AlbumScanModel) -> some View {
        List {
            Section {
                ForEach(albums) { album in
                    Button {
                        Task { await model.scan(album) }
                    } label: {
                        HStack {
                            Text(album.title).foregroundStyle(Color.label)
                            Spacer()
                            Text("\(album.count) 张").foregroundStyle(Color.secondaryLabel)
                        }
                    }
                    .disabled(album.count == 0)
                }
            } header: {
                Text("选择相册")
            } footer: {
                Text(albums.isEmpty
                    ? "还没有自己建的相册。可以在系统相册里新建「我的穿搭」，把自己的穿搭照放进去。"
                    : "只列出你自己建的相册。")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func ready(unseen: Int, model: AlbumScanModel) -> some View {
        List {
            Section {
                HStack {
                    Label("「\(model.albumTitle)」", systemImage: "rectangle.stack")
                        .foregroundStyle(Color.label)
                    Spacer()
                    Text(unseen > 0 ? "\(unseen) 张新照片" : "没有新照片")
                        .foregroundStyle(Color.secondaryLabel)
                }
                Button(unseen > AlbumScan.photosPerRun ? "扫描最新的 \(AlbumScan.photosPerRun) 张" : "开始扫描") {
                    Task { await model.scan() }
                }
                .disabled(unseen == 0)
                Button("换一个相册") { model.chooseAnotherAlbum() }
            } footer: {
                Text("扫描只识别照片里的衣物，不会分辨照片里是谁。合影、朋友的照片里的衣服也会被识别出来。")
            }
            SkipSummarySection(model: model)
        }
        .scrollContentBackground(.hidden)
    }

    private func progress(_ title: String, detail: String) -> some View {
        VStack(spacing: Spacing.control) {
            ProgressView()
            Text(title).font(.headline).foregroundStyle(Color.label).monospacedDigit()
            Text(detail).font(.subheadline).foregroundStyle(Color.secondaryLabel).multilineTextAlignment(.center)
        }
        .padding(Spacing.screen)
    }

    private func recognising(_ batch: Wire.ImportBatchResponse?, model: AlbumScanModel) -> some View {
        let detail: String = if let batch {
            batch.processing > 0
                ? "已识别 \(batch.totalPhotos - batch.processing)/\(batch.totalPhotos) 张，正在找同一件衣服"
                : "正在把同一件衣服归到一起"
        } else {
            "正在识别照片里的衣物"
        }
        return progress(detail, detail: "可以先关掉，下次打开「扫描相册」会接着显示结果。")
            .task { await model.waitForResults() }
    }

    private func finished(added: Int, wears: Int) -> some View {
        ContentUnavailableView {
            Label(
                added == 0 && wears == 0 ? "这次没有加入新衣物" : "加入 \(added) 件，补记 \(wears) 次穿着",
                systemImage: "checkmark.circle"
            )
        } description: {
            Text("相册里有新照片时，打开「添加衣物」会提醒你。")
        }
    }
}

/// "本次识别 N 张，跳过 M 张（…）", with a way to bring judgement-call skips back.
struct SkipSummarySection: View {
    let model: AlbumScanModel

    var body: some View {
        let tally = model.ledger.lastTally
        if tally.kept + tally.skippedTotal > 0 {
            Section {
                Text(tally.summary).foregroundStyle(Color.label)
                ForEach(AlbumScan.SkipReason.allCases.filter(\.canReinclude), id: \.self) { reason in
                    let count = model.ledger.skipped(reason).count
                    if count > 0 {
                        Button("把 \(count) 张「\(reason.label)」照片加回下次扫描") { model.bringBack(reason) }
                    }
                }
                if model.visionUnavailable {
                    Text("这台设备上有些本机检查没能运行（人数、衣物或重复照片），这些照片照常上传识别。")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
                if model.uploadFailures > 0 {
                    Text("\(model.uploadFailures) 张没能上传，下次扫描会再试。")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryLabel)
                }
            } header: {
                Text("上次扫描")
            }
        }
    }
}
