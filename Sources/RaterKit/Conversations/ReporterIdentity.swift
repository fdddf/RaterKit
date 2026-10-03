import Foundation
import Security
import os

/// Where the per-install reporter token lives.
///
/// The token is what lets this device read its own feedback back from the server: the app's
/// API key is baked into the binary and says nothing about *who* is asking, so the server
/// hands a thread only to the device holding the token its feedback was sent with.
protocol ReporterTokenStore: Sendable {
    /// The token, created on first use. nil when it can't be read right now — the Keychain
    /// is unavailable before the first unlock after a reboot — in which case the caller
    /// goes without rather than minting a second identity.
    func token() -> String?
    /// Forgets the token. Every thread sent under it becomes unreachable from this device.
    func reset()
}

extension ReporterTokenStore {
    /// 32 random bytes, base64url without padding — the shape the server accepts.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Practically unreachable; SystemRandomNumberGenerator is also a CSPRNG.
            var rng = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Default implementation: one generic-password item per app id.
///
/// The Keychain rather than UserDefaults so the token survives the app being deleted and
/// reinstalled (current iOS behavior, though Apple doesn't promise it), and so it is
/// carried over by an encrypted backup to a new phone — the conversation should follow
/// the person. `AfterFirstUnlock` lets the offline queue replay from the background.
final class KeychainReporterTokenStore: ReporterTokenStore, @unchecked Sendable {
    private static let service = "com.raterkit.reporter"

    private let account: String
    private let lock = NSLock()
    /// Read once, then served from memory — the Keychain is slow enough to notice on a
    /// polling loop.
    private var cached: String?
    private let logger = Logger(subsystem: "com.raterkit", category: "identity")

    init(appID: String) {
        account = appID
    }

    func token() -> String? {
        lock.withLock {
            if let cached { return cached }

            switch read() {
            case .found(let token):
                cached = token
            case .missing:
                let fresh = Self.generateToken()
                if add(fresh) {
                    cached = fresh
                } else if case .found(let existing) = read() {
                    // Someone else (another process sharing the item) got there first.
                    cached = existing
                }
            case .unavailable:
                return nil
            }
            return cached
        }
    }

    func reset() {
        lock.withLock {
            cached = nil
            SecItemDelete(baseQuery as CFDictionary)
        }
    }

    // MARK: - Keychain

    private enum ReadResult {
        case found(String)
        case missing
        case unavailable
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read() -> ReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                return .unavailable
            }
            return .found(token)
        case errSecItemNotFound:
            return .missing
        default:
            // Most likely errSecInteractionNotAllowed: locked since boot. Not "missing" —
            // minting a new token here would orphan every existing thread.
            logger.notice("reporter token unreadable: \(status)")
            return .unavailable
        }
    }

    private func add(_ token: String) -> Bool {
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { logger.error("reporter token not saved: \(status)") }
        return status == errSecSuccess
    }
}

/// In-memory implementation for unit tests and previews.
final class InMemoryReporterTokenStore: ReporterTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) {
        self.value = value
    }

    func token() -> String? {
        lock.withLock {
            if value == nil { value = Self.generateToken() }
            return value
        }
    }

    func reset() {
        lock.withLock { value = nil }
    }
}
