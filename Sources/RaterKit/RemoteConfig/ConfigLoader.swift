import Foundation
import os

/// Server-provided copy, switches and rule overrides, in the shape the client needs.
public struct RemotePromptConfig: Sendable, Equatable {
    public var isEnabled: Bool
    public var variant: String
    public var appStoreID: String?
    public var copy: RaterCopy
    public var emailRequired: Bool
    public var rules: RemoteRules?
}

/// Fetches and caches remote config.
///
/// Two layers of cache: one in memory for the rest of this run, one on disk so a cold
/// launch has copy immediately. Inside the TTL nothing goes out at all; once it expires
/// the request carries an ETag, so unchanged copy costs a single 304.
public actor ConfigLoader {
    private struct CachedEntry: Codable {
        var response: RemoteConfigResponse
        var etag: String?
        var fetchedAt: Date
        var appVersion: String
        var locale: String
    }

    private let client: RaterAPIClient
    private let ttl: TimeInterval
    private let fallbackCopy: RaterCopy
    private let cacheURL: URL?
    private let logger = Logger(subsystem: "com.raterkit", category: "config")

    private var cached: CachedEntry?
    /// Shared by concurrent callers so several trigger points don't fire several requests.
    private var inFlight: Task<RemotePromptConfig, Never>?

    init(client: RaterAPIClient, ttl: TimeInterval, fallbackCopy: RaterCopy, appID: String) {
        self.client = client
        self.ttl = ttl
        self.fallbackCopy = fallbackCopy
        cacheURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "RaterKit", directoryHint: .isDirectory)
            .appending(path: "config-\(appID).json")
    }

    /// The config to use right now. Any failure falls back to cache or bundled copy —
    /// a server outage must not make the prompt disappear.
    public func configuration(appVersion: String, locale: String) async -> RemotePromptConfig {
        if let inFlight { return await inFlight.value }

        if cached == nil { cached = readDisk() }

        // Cache is fresh and was fetched for this same version and locale.
        if let entry = cached,
           entry.appVersion == appVersion, entry.locale == locale,
           Date().timeIntervalSince(entry.fetchedAt) < ttl {
            return makeConfig(from: entry.response)
        }

        // This Task inherits the actor's isolation, so touching `cached` and `store`
        // inside it is safe; storing it in `inFlight` lets concurrent callers await the
        // very same request.
        let previous = cached
        let task = Task<RemotePromptConfig, Never> {
            do {
                // Drop a stale ETag when the version or locale changed, or the server
                // answers 304 for copy that belongs to a different context.
                let reusableETag = (previous?.appVersion == appVersion && previous?.locale == locale)
                    ? previous?.etag : nil

                let result = try await client.fetchConfig(
                    version: appVersion, locale: locale, etag: reusableETag
                )

                switch result {
                case .fresh(let response, let etag):
                    store(CachedEntry(response: response, etag: etag, fetchedAt: Date(),
                                      appVersion: appVersion, locale: locale))
                    return makeConfig(from: response)

                case .notModified:
                    guard var entry = previous else { return fallbackConfig() }
                    entry.fetchedAt = Date()
                    store(entry)
                    return makeConfig(from: entry.response)
                }
            } catch {
                logger.debug("config fetch failed, falling back to cache: \(error.localizedDescription)")
                return previous.map { makeConfig(from: $0.response) } ?? fallbackConfig()
            }
        }

        inFlight = task
        let config = await task.value
        inFlight = nil
        return config
    }

    /// Drops the cache so the next call definitely refetches. Useful right after
    /// editing copy and wanting to see it.
    public func invalidate() {
        cached = nil
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }

    // MARK: - Private

    private func store(_ entry: CachedEntry) {
        cached = entry
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder.rater.encode(entry).write(to: cacheURL, options: .atomic)
        } catch {
            logger.debug("failed to write config cache: \(error.localizedDescription)")
        }
    }

    private func readDisk() -> CachedEntry? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder.rater.decode(CachedEntry.self, from: data)
    }

    private nonisolated func makeConfig(from response: RemoteConfigResponse) -> RemotePromptConfig {
        var copy = fallbackCopy
        if let prompt = response.prompt {
            copy.promptTitle = prompt.title
            copy.promptMessage = prompt.message
            copy.positiveLabel = prompt.positiveLabel
            copy.negativeLabel = prompt.negativeLabel
            copy.laterLabel = prompt.laterLabel
        }
        if let feedback = response.feedback {
            copy.feedbackTitle = feedback.title
            copy.feedbackMessage = feedback.message
            // An empty array means categories were simply left blank, so keep the
            // bundled defaults rather than showing none.
            if !feedback.categories.isEmpty { copy.categories = feedback.categories }
        }
        return RemotePromptConfig(
            isEnabled: response.enabled,
            variant: response.variant,
            appStoreID: response.appStoreID,
            copy: copy,
            emailRequired: response.feedback?.emailRequired ?? false,
            rules: response.rules
        )
    }

    private nonisolated func fallbackConfig() -> RemotePromptConfig {
        // Treat an unreachable server as enabled: better one extra prompt than the
        // whole feature going silent because config couldn't be fetched.
        RemotePromptConfig(
            isEnabled: true, variant: "fallback", appStoreID: nil,
            copy: fallbackCopy, emailRequired: false, rules: nil
        )
    }
}
