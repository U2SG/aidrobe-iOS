import Foundation
import Security

/// Minimal string store; the Keychain implementation is used in the app and an
/// in-memory one in tests.
public protocol SecureStore: Sendable {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String)
}

public struct KeychainStore: SecureStore {
    private let service: String

    public init(service: String = "app.aidrobe.ios") {
        self.service = service
    }

    public func string(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String?, for key: String) {
        let query = baseQuery(key)
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func string(for key: String) -> String? {
        lock.withLock { values[key] }
    }

    public func set(_ value: String?, for key: String) {
        lock.withLock { values[key] = value }
    }
}

/// Access / refresh tokens, persisted in the secure store.
public struct TokenPair: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?

    public init(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// Token pairs and their session generation are read and changed under one
/// lock. Login/logout starts a generation; refresh only rotates its tokens.
public final class TokenStore: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let generation: UUID
        let tokens: TokenPair?
    }

    private enum Key {
        static let access = "aidrobe.accessToken"
        static let refresh = "aidrobe.refreshToken"
    }

    private let store: any SecureStore
    private let lock = NSLock()
    private var generationID = UUID()

    public init(store: any SecureStore) {
        self.store = store
    }

    public var generation: UUID { lock.withLock { generationID } }
    public var tokens: TokenPair? { snapshot.tokens }
    var snapshot: Snapshot { lock.withLock { snapshotLocked() } }

    public func save(_ tokens: TokenPair) {
        lock.withLock {
            generationID = UUID()
            writeLocked(tokens)
        }
    }

    public func clear() {
        lock.withLock {
            generationID = UUID()
            writeLocked(nil)
        }
    }

    func rotate(_ tokens: TokenPair, ifCurrent expected: Snapshot) -> Snapshot? {
        lock.withLock {
            guard snapshotLocked() == expected else { return nil }
            writeLocked(tokens)
            return snapshotLocked()
        }
    }

    func clear(ifCurrent expected: Snapshot) -> Bool {
        lock.withLock {
            guard snapshotLocked() == expected else { return false }
            generationID = UUID()
            writeLocked(nil)
            return true
        }
    }

    private func snapshotLocked() -> Snapshot {
        let tokens = store.string(for: Key.access).map {
            TokenPair(accessToken: $0, refreshToken: store.string(for: Key.refresh))
        }
        return Snapshot(generation: generationID, tokens: tokens)
    }

    private func writeLocked(_ tokens: TokenPair?) {
        store.set(tokens?.accessToken, for: Key.access)
        store.set(tokens?.refreshToken, for: Key.refresh)
    }
}
