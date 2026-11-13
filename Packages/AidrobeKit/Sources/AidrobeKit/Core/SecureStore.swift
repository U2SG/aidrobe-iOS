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

public final class TokenStore: Sendable {
    private enum Key {
        static let access = "aidrobe.accessToken"
        static let refresh = "aidrobe.refreshToken"
    }

    private let store: any SecureStore

    public init(store: any SecureStore) {
        self.store = store
    }

    public var tokens: TokenPair? {
        guard let access = store.string(for: Key.access) else { return nil }
        return TokenPair(accessToken: access, refreshToken: store.string(for: Key.refresh))
    }

    public func save(_ tokens: TokenPair) {
        store.set(tokens.accessToken, for: Key.access)
        store.set(tokens.refreshToken, for: Key.refresh)
    }

    public func clear() {
        store.set(nil, for: Key.access)
        store.set(nil, for: Key.refresh)
    }
}
