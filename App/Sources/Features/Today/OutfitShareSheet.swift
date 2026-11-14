import SwiftUI
import UIKit

/// Capture the pieces at the tap, including any local swaps. Do not put private
/// locations, feedback, or recommendation reasons into an exported image.
struct OutfitShareDraft: Identifiable {
    let id = UUID()
    let items: [BoardItem]
    let date: String?
}

struct OutfitShareSheet: View {
    let draft: OutfitShareDraft
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.cutoutKey) private var prefersCutout = true
    @State private var picture: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let picture {
                    ScrollView {
                        Image(uiImage: picture)
                            .resizable()
                            .scaledToFit()
                            .overlay(Rectangle().strokeBorder(Color.separator))
                            .accessibilityLabel("搭配分享图")
                            .padding(Spacing.screen)
                    }
                    .safeAreaInset(edge: .bottom) {
                        let item = Image(uiImage: picture)
                        ShareLink(item: item, preview: SharePreview("衣然 · 穿搭", image: item)) {
                            Label("分享图片", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .padding(.horizontal, Spacing.screen)
                        .padding(.vertical, Spacing.tight)
                    }
                } else if failed {
                    ContentUnavailableView {
                        Label("没能生成分享图", systemImage: "photo")
                    } description: {
                        Text("有衣物照片没加载成功，请重试。")
                    } actions: {
                        Button("重试") {
                            failed = false
                            attempt += 1
                        }
                        .buttonStyle(.glass)
                    }
                } else {
                    ProgressView("正在准备分享图…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.background)
            .navigationTitle("分享搭配")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .task(id: attempt) { await prepare() }
        }
    }

    private func prepare() async {
        let requests = draft.items.compactMap { item in item.imageURL.map { (item.id, $0) } }
        guard !requests.isEmpty, requests.count == draft.items.count else {
            failed = true
            return
        }
        let cutout = prefersCutout
        let pictures = await withTaskGroup(of: (String, GarmentRender?).self) { group in
            for (id, url) in requests {
                group.addTask { (id, await GarmentImagePipeline.shared.render(url, cutout: cutout)) }
            }
            var pictures: [String: GarmentRender] = [:]
            for await (id, render) in group { pictures[id] = render }
            return pictures
        }
        guard !Task.isCancelled else { return }
        guard pictures.count == requests.count else {
            failed = true
            return
        }
        let card = OutfitShareCard(draft: draft, pictures: pictures)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.isOpaque = true
        picture = renderer.uiImage
        failed = picture == nil
    }
}

private struct OutfitShareCard: View {
    let draft: OutfitShareDraft
    let pictures: [String: GarmentRender]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            HStack {
                Text("衣然").kicker()
                Spacer()
                if let date = draft.date { Text(date).kicker() }
            }
            Divider().overlay(Color.separator)
            Text("我的一套")
                .font(.display(32, weight: .black))
                .foregroundStyle(Color.label)
            OutfitBoard(items: draft.items, pictures: pictures)
            Text(draft.items.map(\.name).joined(separator: "  ·  "))
                .font(.footnote)
                .foregroundStyle(Color.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.screen)
        .frame(width: 360)
        .background(Color.background)
    }
}
