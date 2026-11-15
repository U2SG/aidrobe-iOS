import Foundation

/// Only a conversation identifier is cached. Its contents and signed image URLs
/// always come from an authenticated server read when the page is reopened.
@MainActor
public struct ConversationBookmark {
    private static let prefix = "aidrobe.ask.last-conversation."
    private let defaults: UserDefaults
    private let key: String

    public init(accountID: String, server: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = Self.prefix + server.absoluteString + "|" + accountID
    }

    public var conversationID: String? { defaults.string(forKey: key) }

    public func save(_ conversationID: String?) {
        if let conversationID { defaults.set(conversationID, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    public static func clearAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// The JWT subject is used only to partition a local bookmark, never to
    /// authorize a request. An unreadable signed-in identity must not fall back
    /// to the development user's saved conversation.
    public static func accountID(accessToken: String?, developmentUserID: String?) -> String? {
        guard let accessToken else { return developmentUserID }
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty else { return nil }
        return subject
    }
}
