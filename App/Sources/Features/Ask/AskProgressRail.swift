import SwiftUI

/// One tick per question along the trailing edge of a conversation. The tick
/// of the question in view is marked; tapping a tick jumps to it. Holding the
/// rail briefly before dragging shows each question and jumps on release, so a
/// quick swipe that starts on the rail still scrolls the page.
struct AskProgressRail: View {
    struct Mark: Identifiable, Equatable {
        let id: UUID
        let question: String
    }

    let marks: [Mark]
    let current: UUID?
    let onSelect: (UUID) -> Void
    /// A quick drag that starts on the rail scrolls the page: the rail sits
    /// above the scroll view, so its touches would never reach it otherwise.
    /// Called with the vertical translation, and the predicted one on release.
    let onPan: (_ translation: CGFloat, _ ended: Bool) -> Void

    @State private var scrubbing: Int?

    private static let maxHeight: CGFloat = 320
    /// Only as wide as the ticks, so it stays out of the text column.
    private static let width: CGFloat = 16

    /// Ticks keep an 8 pt pitch until the rail would outgrow `maxHeight`.
    private var pitch: CGFloat { min(8, Self.maxHeight / CGFloat(max(marks.count, 1))) }

    private var currentIndex: Int? { marks.firstIndex { $0.id == current } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(marks.enumerated()), id: \.element.id) { index, _ in
                let highlighted = index == (scrubbing ?? currentIndex)
                Capsule()
                    .fill(highlighted ? Color.label : Color.tertiaryLabel)
                    .frame(width: highlighted ? 14 : 9, height: 2)
                    .frame(height: pitch, alignment: .center)
            }
        }
        .frame(width: Self.width, alignment: .trailing)
        .padding(.vertical, Spacing.tight)
        .contentShape(.rect)
        .onTapGesture { location in onSelect(marks[index(at: location.y)].id) }
        .gesture(scrub.exclusively(before: pan))
        .overlay(alignment: .topTrailing) { preview }
        .animation(.snappy(duration: 0.15), value: scrubbing ?? currentIndex)
        .sensoryFeedback(.selection, trigger: scrubbing) { _, new in new != nil }
        .accessibilityElement()
        .accessibilityLabel("对话进度")
        .accessibilityValue(currentIndex.map { "第\($0 + 1)问，共\(marks.count)问" } ?? "共\(marks.count)问")
        .accessibilityAdjustableAction { direction in
            let index = currentIndex ?? 0
            let target = direction == .increment ? index + 1 : index - 1
            if marks.indices.contains(target) { onSelect(marks[target].id) }
        }
        .accessibilityIdentifier("ask.progressRail")
    }

    private func index(at y: CGFloat) -> Int {
        min(max(Int((y - Spacing.tight) / pitch), 0), marks.count - 1)
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { onPan($0.translation.height, false) }
            .onEnded { onPan($0.predictedEndTranslation.height, true) }
    }

    private var scrub: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case let .second(true, drag?) = value { scrubbing = index(at: drag.location.y) }
            }
            .onEnded { _ in
                if let scrubbing, marks.indices.contains(scrubbing) { onSelect(marks[scrubbing].id) }
                scrubbing = nil
            }
    }

    @ViewBuilder private var preview: some View {
        if let scrubbing, marks.indices.contains(scrubbing) {
            Text(marks[scrubbing].question)
                .font(.subheadline)
                .foregroundStyle(Color.label)
                .lineLimit(2)
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, Spacing.tight)
                .frame(width: 220, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .offset(x: -(Self.width + Spacing.tight), y: Spacing.tight + pitch * CGFloat(scrubbing) - 14)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}
