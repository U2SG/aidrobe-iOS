import SwiftUI

/// One tick per question along the trailing edge of a conversation, like the
/// section index of a contact list. The tick of the question in view is
/// marked; touching the rail shows the question under the finger and jumps
/// there on release. The rail does not scroll the page.
struct AskProgressRail: View {
    struct Mark: Identifiable, Equatable {
        let id: UUID
        let question: String
    }

    let marks: [Mark]
    let current: UUID?
    let onSelect: (UUID) -> Void

    /// Resets on its own when the system cancels the touch.
    @GestureState private var scrubbing: Int?

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
        .gesture(scrub)
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

    /// Starts on touch-down; lifting without moving is a tap on that tick.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($scrubbing) { value, state, _ in state = index(at: value.location.y) }
            .onEnded { onSelect(marks[index(at: $0.location.y)].id) }
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
