#if DEBUG
import AidrobeKit
import PhotosUI
import SwiftUI

/// Debug-only experiment bench for on-device background removal (analysis
/// report, task 4 / experiment 5.1). Launch with `-AidrobeLiftLab`, pick real
/// wardrobe photos, and compare each original with its Vision subject lift.
/// Rows flag the cases the heuristic would reject (several instances, frame
/// filled, nothing found), which are exactly the ones to inspect by eye.
struct SubjectLiftLab: View {
    struct Sample: Identifiable {
        let id = UUID()
        let original: UIImage
        var lifted: UIImage?
        var detail: String
        var accepted: Bool
    }

    @State private var picks: [PhotosPickerItem] = []
    @State private var samples: [Sample] = []

    var body: some View {
        NavigationStack {
            List {
                PhotosPicker(selection: $picks, maxSelectionCount: 50, matching: .images) {
                    Label("选择要测试的照片", systemImage: "photo.stack")
                }
                if !samples.isEmpty {
                    Section("通过 \(samples.filter { $0.accepted }.count) / \(samples.count)") {
                        ForEach(samples) { sample in
                            HStack(spacing: 12) {
                                Image(uiImage: sample.original).resizable().scaledToFit().frame(width: 96, height: 128)
                                Group {
                                    if let lifted = sample.lifted {
                                        Image(uiImage: lifted).resizable().scaledToFit()
                                    } else {
                                        Image(systemName: "xmark").foregroundStyle(Color.danger)
                                    }
                                }
                                .frame(width: 96, height: 128)
                                .background(Color.fill)
                                VStack(alignment: .leading) {
                                    Label(sample.accepted ? "可用" : "保留原图",
                                          systemImage: sample.accepted ? "checkmark.circle" : "exclamationmark.circle")
                                        .foregroundStyle(sample.accepted ? Color.success : Color.warning)
                                    Text(sample.detail).font(.caption).foregroundStyle(Color.secondaryLabel)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("抠图对照")
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                picks = []
                Task { await run(items) }
            }
        }
    }

    private func run(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data), let cgImage = image.cgImage else { continue }
            do {
                let result = try await SubjectLift.lift(cgImage)
                samples.append(Sample(
                    original: image,
                    lifted: UIImage(cgImage: result.image),
                    detail: String(format: "实例 %d · 覆盖 %.0f%%", result.instanceCount, result.coverage * 100),
                    accepted: result.looksLikeSingleGarment
                ))
            } catch {
                samples.append(Sample(original: image, lifted: nil, detail: "\(error)", accepted: false))
            }
        }
    }
}

struct SubjectLiftLabModifier: ViewModifier {
    @State private var presented = ProcessInfo.processInfo.arguments.contains("-AidrobeLiftLab")

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $presented) { SubjectLiftLab() }
    }
}
#endif
