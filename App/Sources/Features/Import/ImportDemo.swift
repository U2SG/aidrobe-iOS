#if DEBUG
import SwiftUI

/// Simulator-only harness: launch with `-AidrobeImportDemo` to open the import
/// sheet and feed it one generated photo, exercising upload → recognition
/// against the local backend without UI automation.
struct ImportDemoModifier: ViewModifier {
    @State private var presented = ProcessInfo.processInfo.arguments.contains("-AidrobeImportDemo")

    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented) {
            ImportFlowView(autoImport: [Self.samplePhoto()])
        }
    }

    static func samplePhoto() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { context in
            UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor(red: 0.20, green: 0.32, blue: 0.55, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 120, y: 160, width: 360, height: 480), cornerRadius: 40).fill()
        }
    }
}

extension View {
    func importDemo() -> some View { modifier(ImportDemoModifier()) }
}
#endif
