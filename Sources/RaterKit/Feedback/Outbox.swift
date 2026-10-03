import Foundation
import os

/// Something the outbox can hold: keyed by its idempotency key, so re-queuing the same
/// item overwrites rather than piling up, and the server dedupes a replay of one that did
/// land after all.
protocol OutboxItem: Codable, Sendable {
    var idempotencyKey: String { get }
    var queuedAt: Date { get }
    /// How many attempts have been made. Past the cap it is dropped, so one bad entry
    /// can't wedge the head of the queue forever.
    var attempts: Int { get set }
}

/// One feedback waiting to be resent. Attachment bytes are inlined — a compressed
/// screenshot is only a few hundred KB, not worth storing separately and then having
/// to keep the references in sync.
struct PendingSubmission: OutboxItem {
    var idempotencyKey: String
    var message: String
    var category: String?
    var email: String?
    var metadata: [String: String]
    var device: DiagnosticsPayload
    var attachments: [Payload]
    var queuedAt: Date
    var attempts: Int

    struct Payload: Codable, Sendable {
        var data: Data
        var contentType: String
    }
}

/// On-disk queue for failed sends, replayed on next launch or when the network comes back.
/// One instance per kind of item, each in its own directory.
///
/// Lives in Caches: losing it costs nothing in correctness (the user already saw
/// "sent"), and it isn't worth consuming their backup quota.
actor Outbox<Item: OutboxItem> {
    /// Cap on queued entries, so repeated offline submissions can't fill the disk.
    private let maxEntries = 20
    /// Cap on retries for a single entry.
    private let maxAttempts = 5

    private let directory: URL?
    private let logger = Logger(subsystem: "com.raterkit", category: "outbox")

    /// `name` keeps each kind of item in its own directory. The default is the one
    /// submissions have always used, so a queue written by an older version still replays.
    init(appID: String, name: String = "outbox") {
        directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "RaterKit/\(name)-\(appID)", directoryHint: .isDirectory)
    }

    func enqueue(_ submission: Item) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // Named by idempotency key, so re-queuing the same feedback overwrites
            // rather than piling up.
            let url = directory.appending(path: "\(submission.idempotencyKey).json")
            try JSONEncoder.rater.encode(submission).write(to: url, options: .atomic)
            trimIfNeeded()
            logger.debug("queued for retry: \(submission.idempotencyKey)")
        } catch {
            logger.error("failed to queue: \(error.localizedDescription)")
        }
    }

    func pending() -> [Item] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else { return [] }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Item? in
                guard let data = try? Data(contentsOf: url),
                      let item = try? JSONDecoder.rater.decode(Item.self, from: data)
                else {
                    // Undecodable usually means an old format or a torn write — just drop it.
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return item
            }
            .sorted { $0.queuedAt < $1.queuedAt }
    }

    func remove(_ idempotencyKey: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(
            at: directory.appending(path: "\(idempotencyKey).json")
        )
    }

    /// Records a failed attempt. Drops the entry once the retry cap is hit;
    /// returns true when it was given up on.
    @discardableResult
    func recordAttempt(_ submission: Item) -> Bool {
        var updated = submission
        updated.attempts += 1
        if updated.attempts >= maxAttempts {
            logger.notice("giving up after \(self.maxAttempts) attempts: \(submission.idempotencyKey)")
            remove(submission.idempotencyKey)
            return true
        }
        enqueue(updated)
        return false
    }

    func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    var count: Int {
        pending().count
    }

    /// Drops the oldest entries once the cap is exceeded.
    private func trimIfNeeded() {
        let items = pending()
        guard items.count > maxEntries else { return }
        for item in items.prefix(items.count - maxEntries) {
            remove(item.idempotencyKey)
        }
    }
}
