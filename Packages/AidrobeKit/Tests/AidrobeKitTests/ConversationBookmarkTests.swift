import Foundation
import Testing
@testable import AidrobeKit

@MainActor
@Suite struct ConversationBookmarkTests {
    @Test func partitionsByAccountAndServerWithoutCachingConversationContents() throws {
        let suite = "ConversationBookmarkTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = URL(string: "https://api.example.test")!
        let alice = ConversationBookmark(accountID: "alice", server: server, defaults: defaults)
        let bob = ConversationBookmark(accountID: "bob", server: server, defaults: defaults)
        let development = ConversationBookmark(
            accountID: "alice", server: URL(string: "https://dev.example.test")!, defaults: defaults
        )

        alice.save("conversation-a")
        bob.save("conversation-b")
        development.save("conversation-dev")

        let reopened = ConversationBookmark(accountID: "alice", server: server, defaults: defaults)
        #expect(reopened.conversationID == "conversation-a")
        #expect(bob.conversationID == "conversation-b")
        #expect(development.conversationID == "conversation-dev")
        #expect(Set(defaults.persistentDomain(forName: suite)?.values.compactMap { $0 as? String } ?? [])
            == ["conversation-a", "conversation-b", "conversation-dev"])

        alice.save(nil)
        #expect(reopened.conversationID == nil)
        #expect(bob.conversationID == "conversation-b")
    }

    @Test func signOutClearsBookmarksWithoutRemovingOtherSettings() throws {
        let suite = "ConversationBookmarkTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("system", forKey: "appearance")
        let bookmark = ConversationBookmark(
            accountID: "alice", server: URL(string: "https://api.example.test")!, defaults: defaults
        )
        bookmark.save("conversation-a")

        ConversationBookmark.clearAll(defaults: defaults)

        #expect(bookmark.conversationID == nil)
        #expect(defaults.string(forKey: "appearance") == "system")
    }

    @Test func tokenRotationKeepsPartitionAndMalformedIdentityNeverUsesDevelopmentBookmark() throws {
        func token(subject: String, expiry: Int) throws -> String {
            let payload = try JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expiry])
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "header.\(payload).signature"
        }
        #expect(ConversationBookmark.accountID(accessToken: try token(subject: "alice", expiry: 1), developmentUserID: "dev") == "alice")
        #expect(ConversationBookmark.accountID(accessToken: try token(subject: "alice", expiry: 2), developmentUserID: "dev") == "alice")
        #expect(ConversationBookmark.accountID(accessToken: "not.a.jwt", developmentUserID: "dev") == nil)
        #expect(ConversationBookmark.accountID(accessToken: nil, developmentUserID: "dev") == "dev")
        #expect(ConversationBookmark.accountID(accessToken: nil, developmentUserID: nil) == nil)
    }
}
