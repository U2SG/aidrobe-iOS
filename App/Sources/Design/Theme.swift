import SwiftUI

/// Brand tokens from the RN client's `src/theme/design.ts` (light) plus a dark
/// palette. Colours live in Assets.xcassets so they follow the system appearance.
extension Color {
    static let background = Color("Background")
    static let groupedBackground = Color("GroupedBackground")
    static let elevatedBackground = Color("ElevatedBackground")
    static let fill = Color("Fill")
    static let separator = Color("Separator")
    static let label = Color("Label")
    static let secondaryLabel = Color("SecondaryLabel")
    static let tertiaryLabel = Color("TertiaryLabel")
    static let accent = Color("AccentColor")
    static let accentSoft = Color("AccentSoft")
    static let success = Color("Success")
    static let warning = Color("Warning")
    static let danger = Color("Danger")
}

enum Spacing {
    static let screen: CGFloat = 20
    static let section: CGFloat = 24
    static let row: CGFloat = 16
    static let control: CGFloat = 12
}
