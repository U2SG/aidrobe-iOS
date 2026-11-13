import SwiftUI

/// Short-lived confirmation floating above the bottom bar.
private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.label)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .padding(.top, Spacing.tight)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        self.message = nil
                    }
            }
        }
        .animation(.snappy, value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

/// Selectable capsule used for filters and tags.
struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(isSelected ? Color.background : Color.secondaryLabel)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(isSelected ? Color.label : Color.clear, in: .capsule)
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.separator))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Wraps children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(subviews, width: bounds.width).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}

/// Label on the left, value on the right, hairline below: the row every
/// detail list on a page is built from.
struct FactRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).foregroundStyle(Color.secondaryLabel)
                Spacer(minLength: Spacing.row)
                value.foregroundStyle(Color.label)
            }
            .font(.body)
            .frame(minHeight: 52)
            Divider().overlay(Color.separator)
        }
    }
}
