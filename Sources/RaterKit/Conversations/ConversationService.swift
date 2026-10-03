import Foundation
import os

/// A message the user wrote that hasn't reached the server yet.
struct PendingMessage: OutboxItem, Identifiable {
    var idempotencyKey: String
    var threadID: String
    var body: String
    var queuedAt: Date
    var attempts: Int

    var id: String { idempotencyKey }
}

/// The conversation side of RaterKit: reading threads, writing back, and the queue of
/// messages written while offline.
///
/// Polling is the transport. The thread view asks for `after: <last seq>` every few
/// seconds while it is on screen; nothing runs in the background beyond the badge refresh
/// `Rater` does when the app comes to the foreground.
actor ConversationService {
    private let client: RaterAPIClient
    private let outbox: Outbox<PendingMessage>
    private let reporter: any ReporterTokenStore
    private let logger = Logger(subsystem: "com.raterkit", category: "conversations")

    init(client: RaterAPIClient, outbox: Outbox<PendingMessage>, reporter: any ReporterTokenStore) {
        self.client = client
        self.outbox = outbox
        self.reporter = reporter
    }

    func threads(before: Int64? = nil) async throws -> ThreadPage {
        try await client.listThreads(before: before)
    }

    func thread(id: String, after: Int64? = nil) async throws -> ThreadResponse {
        try await client.fetchThread(id: id, after: after)
    }

    func inbox() async throws -> InboxResponse {
        try await client.fetchInbox()
    }

    func markRead(threadID: String, seq: Int64) async throws {
        try await client.markRead(threadID: threadID, seq: seq)
    }

    /// Sends one message. A failure worth retrying leaves it queued — under the same
    /// idempotency key, so a send that did land and only lost its response isn't posted
    /// twice when the queue replays it.
    func send(_ message: PendingMessage) async throws -> ThreadMessage {
        do {
            let sent = try await client.postMessage(
                threadID: message.threadID,
                body: ThreadMessageBody(idempotencyKey: message.idempotencyKey, body: message.body)
            )
            await outbox.remove(message.idempotencyKey)
            return sent
        } catch {
            if (error as? RaterError)?.isRetryable ?? true {
                await outbox.enqueue(message)
            } else {
                await outbox.remove(message.idempotencyKey)
            }
            throw error
        }
    }

    /// Messages still waiting to go out, for one thread — shown under its conversation.
    func pending(threadID: String) async -> [PendingMessage] {
        await outbox.pending().filter { $0.threadID == threadID }
    }

    /// Gives up on a queued message the user chose to discard.
    func discard(_ message: PendingMessage) async {
        await outbox.remove(message.idempotencyKey)
    }

    /// Replays the queue. Called at launch, when the network comes back, and when a
    /// conversation opens.
    func flush() async {
        for item in await outbox.pending() {
            do {
                _ = try await client.postMessage(
                    threadID: item.threadID,
                    body: ThreadMessageBody(idempotencyKey: item.idempotencyKey, body: item.body)
                )
                await outbox.remove(item.idempotencyKey)
            } catch {
                // A 4xx means the message itself won't ever go — the thread was deleted or
                // marked spam — so retrying changes nothing.
                if let raterError = error as? RaterError, !raterError.isRetryable {
                    await outbox.remove(item.idempotencyKey)
                    logger.notice("rejected by the server, dropping: \(item.idempotencyKey)")
                } else {
                    await outbox.recordAttempt(item)
                    break
                }
            }
        }
    }

    /// Erases everything this device sent from the server, then forgets the token, so
    /// whatever is sent next starts a history of its own.
    func deleteHistory() async throws {
        try await client.deleteHistory()
        await outbox.clear()
        reporter.reset()
    }
}
