import Foundation

public enum DesignContinuity {
    /// A matching saved receipt proves that an additive request field was
    /// honored; older servers may otherwise ignore it without an error.
    public static func matches(_ expected: Wire.DesignContextRef, _ actual: Wire.DesignContextSnapshot?) -> Bool {
        actual?.conversationId.lowercased() == expected.conversationId.lowercased()
            && actual?.revision == expected.expectedRevision
    }
}

public struct StylingExperienceState: Sendable {
    public let appreciated: Wire.StylingExperienceResponse?
    public let wantToTry: Wire.StylingExperienceResponse?
    public let wornDate: String?
    public let wearFeedback: Wire.StylingExperienceResponse?

    public init(_ result: Wire.StylingExperienceListResponse) {
        appreciated = result.items.first { $0.kind == .appreciated }
        wantToTry = result.items.first { $0.kind == .wantToTry }
        wornDate = result.latestWornDate
        // An intention or an adopted plan never unlocks a wear reflection.
        wearFeedback = result.latestWornDate.flatMap { day in
            result.items.first { $0.kind == .wearFeedback && $0.wornDate == day }
        }
    }
}
