import SwiftUI
import UIKit

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
    static let section: CGFloat = 32
    static let row: CGFloat = 16
    static let control: CGFloat = 12
    static let tight: CGFloat = 8
}

enum Radius {
    static let tile: CGFloat = 14
    static let card: CGFloat = 24
}

/// The app reads like a daily page: Songti for headlines, the system face for
/// everything you operate. Songti SC is one of Apple's on-demand system fonts,
/// so it is requested once and headlines use the system serif until it lands.
extension Font {
    enum DisplayWeight: String, CaseIterable {
        case regular = "STSongti-SC-Regular"
        case bold = "STSongti-SC-Bold"
        case black = "STSongti-SC-Black"

        var fallback: Font.Weight {
            switch self {
            case .regular: .regular
            case .bold: .semibold
            case .black: .bold
            }
        }
    }

    @MainActor
    static func display(_ size: CGFloat, weight: DisplayWeight = .bold, relativeTo style: TextStyle = .title) -> Font {
        Typography.shared.hasDisplayFace
            ? .custom(weight.rawValue, size: size, relativeTo: style)
            : .system(size: size, weight: weight.fallback, design: .serif)
    }
}

@MainActor
@Observable
final class Typography {
    static let shared = Typography()

    private(set) var hasDisplayFace = Typography.isInstalled

    private static var isInstalled: Bool {
        Font.DisplayWeight.allCases.allSatisfy { UIFont(name: $0.rawValue, size: 12) != nil }
    }

    /// Asks the system for Songti SC, then restyles headlines and navigation titles.
    func install() {
        applyNavigationTitles()
        guard !hasDisplayFace else { return }
        let descriptors = Font.DisplayWeight.allCases.map {
            CTFontDescriptorCreateWithNameAndSize($0.rawValue as CFString, 0)
        }
        Self.request(descriptors as CFArray) {
            self.hasDisplayFace = Self.isInstalled
            self.applyNavigationTitles()
        }
    }

    /// CoreText answers on its own queue, so the callback must not inherit main-actor isolation.
    private nonisolated static func request(_ descriptors: CFArray, then finish: @escaping @MainActor @Sendable () -> Void) {
        CTFontManagerRequestFonts(descriptors) { _ in
            Task { @MainActor in finish() }
        }
    }

    private func applyNavigationTitles() {
        let ink = UIColor(named: "Label") ?? .label
        let serif = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle).withDesign(.serif)
        let large = UIFont(name: Font.DisplayWeight.black.rawValue, size: 32)
            ?? UIFont(descriptor: serif?.withSymbolicTraits(.traitBold) ?? .init(), size: 32)
        let inline = UIFont(name: Font.DisplayWeight.bold.rawValue, size: 17) ?? .preferredFont(forTextStyle: .headline)
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: large, .foregroundColor: ink]
        bar.titleTextAttributes = [.font: inline, .foregroundColor: ink]
    }
}

extension View {
    /// Small spaced label that opens a section, like a magazine kicker.
    func kicker() -> some View {
        font(.caption.weight(.medium))
            .kerning(1.5)
            .foregroundStyle(Color.tertiaryLabel)
    }
}

/// A kicker plus hairline that starts each section of a page.
struct SectionHeading: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            Divider().overlay(Color.separator)
            Text(title).kicker()
        }
    }
}
