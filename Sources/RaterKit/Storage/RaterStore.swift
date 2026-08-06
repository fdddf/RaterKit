import Foundation

/// Persistence seam, so tests can swap in an in-memory implementation.
public protocol RaterStore: Sendable {
    func load() -> RaterState
    func save(_ state: RaterState)
    func clear()
}

extension RaterStore {
    /// Read-modify-write in one call, so call sites don't repeat three lines.
    @discardableResult
    func mutate(_ body: (inout RaterState) -> Void) -> RaterState {
        var state = load()
        body(&state)
        save(state)
        return state
    }
}

/// Default implementation: one JSON blob under a single UserDefaults key.
///
/// `UserDefaults` is thread-safe but isn't marked `Sendable`, hence `@unchecked` —
/// all we do with it is read and write one key, with no state carried across calls.
public struct UserDefaultsStore: RaterStore, @unchecked Sendable {
    static let key = "com.raterkit.state"

    private let defaults: UserDefaults

    public init(suiteName: String? = nil) {
        // A bad suite name makes UserDefaults(suiteName:) return nil. Fall back to
        // standard rather than crashing — losing extension sharing beats taking the
        // host app down at launch.
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> RaterState {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder.rater.decode(RaterState.self, from: data)
        else {
            // First run: record the install date now, or daysSinceInstall stays 0 forever.
            let fresh = RaterState()
            save(fresh)
            return fresh
        }
        return state
    }

    public func save(_ state: RaterState) {
        guard let data = try? JSONEncoder.rater.encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// In-memory implementation for unit tests and SwiftUI previews.
public final class InMemoryStore: RaterStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: RaterState

    public init(_ state: RaterState = RaterState()) {
        self.state = state
    }

    public func load() -> RaterState {
        lock.withLock { state }
    }

    public func save(_ newValue: RaterState) {
        lock.withLock { state = newValue }
    }

    public func clear() {
        lock.withLock { state = RaterState() }
    }
}

extension JSONDecoder {
    static let rater: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

extension JSONEncoder {
    static let rater: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}
