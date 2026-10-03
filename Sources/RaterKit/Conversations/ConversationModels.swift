import Foundation
import Observation

/// Drives the conversation list. Polls while it is on screen, slowly — the list only has
/// to notice a new reply, not render it.
@MainActor
@Observable
final class ConversationListModel {
    /// nil until the first load lands.
    private(set) var threads: [ThreadSummary]?
    private(set) var nextBefore: Int64?
    private(set) var errorMessage: String?
    private(set) var isLoadingMore = false

    private let rater: Rater
    static let pollInterval: Duration = .seconds(15)

    init(rater: Rater = .shared) {
        self.rater = rater
    }

    /// Refreshes the first page, keeping any older pages already loaded behind it.
    func load() async {
        guard let service = rater.conversationService else {
            errorMessage = RaterError.notConfigured.localizedDescription
            return
        }
        do {
            let page = try await service.threads()
            let fresh = Set(page.items.map(\.id))
            let cutoff = page.items.last?.lastMessageAt ?? .distantFuture
            let older = (threads ?? []).filter { !fresh.contains($0.id) && $0.lastMessageAt < cutoff }
            threads = page.items + (page.nextBefore == nil ? [] : older)
            if threads?.count == page.items.count { nextBefore = page.nextBefore }
            errorMessage = nil
            syncBadge()
        } catch {
            // Keep showing what's already there; only an empty screen needs the error.
            if threads == nil { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard let before = nextBefore, !isLoadingMore,
              let service = rater.conversationService else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.threads(before: before)
            let known = Set((threads ?? []).map(\.id))
            threads = (threads ?? []) + page.items.filter { !known.contains($0.id) }
            nextBefore = page.nextBefore
        } catch {
            // The row that asked for more stays put, and asks again when it reappears.
        }
    }

    func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// With every thread loaded, the list itself is the authority on the badge — and a
    /// non-empty list means this device has conversations even if local state, which a
    /// reinstall wipes while the Keychain token survives, has forgotten that.
    private func syncBadge() {
        guard let threads else { return }
        if !threads.isEmpty { rater.noteConversationsExist() }
        if nextBefore == nil {
            rater.unreadCount = threads.reduce(0) { $0 + $1.unreadCount }
        }
    }
}

/// A message the user wrote, between the send button and the server's answer.
struct OutgoingMessage: Identifiable, Equatable {
    enum State: Equatable {
        case sending
        /// `queued`: it will go by itself once the network is back.
        case failed(queued: Bool)
    }

    var pending: PendingMessage
    var state: State

    var id: String { pending.id }

    static func == (lhs: OutgoingMessage, rhs: OutgoingMessage) -> Bool {
        lhs.id == rhs.id && lhs.state == rhs.state
    }
}

/// Drives one conversation: polls for new messages while on screen, sends, retries, and
/// moves the read marker.
@MainActor
@Observable
final class ConversationThreadModel {
    let threadID: String
    /// What the list knew, so the header has something to show before the first fetch.
    private(set) var summary: ThreadSummary?
    private(set) var detail: ThreadDetail?
    private(set) var messages: [ThreadMessage] = []
    private(set) var outgoing: [OutgoingMessage] = []
    private(set) var errorMessage: String?
    var draft = ""

    private let rater: Rater
    static let pollInterval: Duration = .seconds(5)
    /// The server's cap on one message.
    static let maxCharacters = 4000

    init(threadID: String, summary: ThreadSummary?, rater: Rater = .shared) {
        self.threadID = threadID
        self.summary = summary
        self.rater = rater
    }

    var lastSeq: Int64? { messages.last?.seq }

    var isResolved: Bool { (detail?.summary ?? summary)?.isResolved ?? false }

    var canSend: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= Self.maxCharacters
    }

    /// The whole life of the screen: replay anything queued for this thread, then poll
    /// until the view goes away and cancels the task.
    func run() async {
        guard let service = rater.conversationService else {
            errorMessage = RaterError.notConfigured.localizedDescription
            return
        }
        let queued = await service.pending(threadID: threadID)
        let shown = Set(outgoing.map(\.id))
        outgoing += queued.filter { !shown.contains($0.id) }
            .map { OutgoingMessage(pending: $0, state: .failed(queued: true)) }
        await service.flush()
        let remaining = Set(await service.pending(threadID: threadID).map(\.id))
        outgoing.removeAll { !remaining.contains($0.id) && $0.state != .sending }

        while !Task.isCancelled {
            // A fetch that lands mid-send could show the new message twice — once as
            // the server's copy, once still in `outgoing` — so skip a beat instead.
            if !outgoing.contains(where: { $0.state == .sending }) {
                await refresh()
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func refresh() async {
        guard let service = rater.conversationService else { return }
        do {
            let response = try await service.thread(id: threadID, after: lastSeq)
            detail = response.thread
            summary = response.thread.summary
            merge(response.messages)
            errorMessage = nil
            if response.thread.summary.unreadCount > 0, let seq = lastSeq {
                try? await service.markRead(threadID: threadID, seq: seq)
                await rater.refreshUnreadCount()
            }
        } catch {
            if detail == nil { errorMessage = error.localizedDescription }
        }
    }

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        let message = PendingMessage(
            idempotencyKey: UUID().uuidString, threadID: threadID,
            body: body, queuedAt: Date(), attempts: 0
        )
        outgoing.append(OutgoingMessage(pending: message, state: .sending))
        await deliver(message)
    }

    func retry(_ message: OutgoingMessage) async {
        await deliver(message.pending)
    }

    func discard(_ message: OutgoingMessage) async {
        outgoing.removeAll { $0.id == message.id }
        await rater.conversationService?.discard(message.pending)
    }

    private func deliver(_ message: PendingMessage) async {
        guard let service = rater.conversationService else { return }
        setState(.sending, for: message.id)
        do {
            let sent = try await service.send(message)
            outgoing.removeAll { $0.id == message.id }
            merge([sent])
            // Writing back reopens a resolved thread; the header should say so now
            // rather than on the next poll.
            await refresh()
        } catch {
            let queued = (error as? RaterError)?.isRetryable ?? true
            setState(.failed(queued: queued), for: message.id)
        }
    }

    private func setState(_ state: OutgoingMessage.State, for id: String) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[index].state = state
    }

    private func merge(_ incoming: [ThreadMessage]) {
        guard !incoming.isEmpty else { return }
        let known = Set(messages.map(\.id))
        messages = (messages + incoming.filter { !known.contains($0.id) }).sorted { $0.seq < $1.seq }
    }
}
