import Foundation
import Testing
@testable import RaterKit

private let endpoint = URL(string: "https://example.test")!

private func makeClient(
    _ transport: MockTransport,
    reporter: (any ReporterTokenStore)? = InMemoryReporterTokenStore("reporter-token-0123456789abcdefghijklmnop")
) -> RaterAPIClient {
    RaterAPIClient(endpoint: endpoint, apiKey: "rtr_pub_test", transport: transport, reporter: reporter)
}

private func makeService(
    _ transport: MockTransport,
    outbox: Outbox<PendingMessage>,
    reporter: InMemoryReporterTokenStore = .init("reporter-token-0123456789abcdefghijklmnop")
) -> ConversationService {
    ConversationService(client: makeClient(transport, reporter: reporter), outbox: outbox, reporter: reporter)
}

/// A separate queue directory per test, so they cannot interfere with each other.
private func makeOutbox() -> Outbox<PendingMessage> {
    Outbox(appID: "test-\(UUID().uuidString)", name: "messages")
}

private func pendingMessage(_ body: String = "Still broken on 2.3.0") -> PendingMessage {
    PendingMessage(
        idempotencyKey: UUID().uuidString, threadID: "fb_abc",
        body: body, queuedAt: Date(), attempts: 0
    )
}

private let threadsJSON = """
{"items":[{"id":"fb_abc","created_at":1791010117497,"last_message_at":1791010117762,
 "status":"resolved","category":"bug","preview":"Only big ones","last_author":"admin",
 "unread_count":2}],"next_before":null}
"""

private let threadJSON = """
{"thread":{"id":"fb_abc","created_at":1791010117497,"last_message_at":1791010117762,
 "status":"open","category":"bug","preview":"Only big ones","last_author":"user",
 "unread_count":1,"message":"Export crashes","attachment_count":2},
 "messages":[
  {"seq":7,"id":"msg_1","author":"admin","body":"Which iOS?","created_at":1791010117600},
  {"seq":9,"id":"msg_2","author":"user","body":"Only big ones","created_at":1791010117762}]}
"""

private let messageJSON = """
{"message":{"seq":10,"id":"msg_3","author":"user","body":"Still broken on 2.3.0",
 "created_at":1791010118000},"duplicate":false}
"""

@Suite("Conversations: API client")
struct ConversationClientTests {

    @Test("a submission carries the reporter token, so it becomes a thread")
    func submissionCarriesReporter() async throws {
        let transport = MockTransport([.init(status: 201, json: #"{"id":"fb_abc","upload_token":null,"expires_at":0,"max_attachment_bytes":1,"duplicate":false}"#)])
        _ = try await makeClient(transport).createFeedback(
            FeedbackSubmissionBody(
                idempotencyKey: "key-123", message: "something is wrong", category: nil,
                email: nil, attachmentCount: 0, device: DiagnosticsPayload(), metadata: nil
            )
        )
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Rater-Reporter") == "reporter-token-0123456789abcdefghijklmnop")
    }

    @Test("a submission still goes out without a token")
    func submissionWithoutReporter() async throws {
        let transport = MockTransport([.init(status: 201, json: #"{"id":"fb_abc","upload_token":null,"expires_at":0,"max_attachment_bytes":1,"duplicate":false}"#)])
        _ = try await makeClient(transport, reporter: nil).createFeedback(
            FeedbackSubmissionBody(
                idempotencyKey: "key-123", message: "something is wrong", category: nil,
                email: nil, attachmentCount: 0, device: DiagnosticsPayload(), metadata: nil
            )
        )
        #expect(transport.requests.first?.value(forHTTPHeaderField: "X-Rater-Reporter") == nil)
    }

    @Test("decodes the thread list, with millisecond timestamps")
    func decodesThreads() async throws {
        let transport = MockTransport([.init(json: threadsJSON)])
        let page = try await makeClient(transport).listThreads()

        let thread = try #require(page.items.first)
        #expect(thread.id == "fb_abc")
        #expect(thread.isResolved)
        #expect(thread.unreadCount == 2)
        #expect(abs(thread.lastMessageAt.timeIntervalSince1970 - 1_791_010_117.762) < 0.001)
        #expect(page.nextBefore == nil)

        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/v1/threads")
        #expect(request.value(forHTTPHeaderField: "X-Rater-Key") == "rtr_pub_test")
        #expect(request.value(forHTTPHeaderField: "X-Rater-Reporter") != nil)
    }

    @Test("decodes a thread, its flattened header and its messages")
    func decodesThread() async throws {
        let transport = MockTransport([.init(json: threadJSON)])
        let response = try await makeClient(transport).fetchThread(id: "fb_abc", after: 5)

        #expect(response.thread.message == "Export crashes")
        #expect(response.thread.attachmentCount == 2)
        #expect(response.thread.summary.unreadCount == 1)
        #expect(response.messages.map(\.seq) == [7, 9])
        #expect(response.messages.first?.isFromUser == false)
        #expect(transport.requests.first?.url?.query()?.contains("after=5") == true)
    }

    @Test("posts a message as snake_case with its idempotency key")
    func postsMessage() async throws {
        let transport = MockTransport([.init(status: 201, json: messageJSON)])
        let sent = try await makeClient(transport).postMessage(
            threadID: "fb_abc", body: ThreadMessageBody(idempotencyKey: "key-abc-123", body: "hello")
        )
        #expect(sent.seq == 10)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/v1/threads/fb_abc/messages")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains(#""idempotency_key":"key-abc-123""#))
    }

    @Test("asks nothing of the server when the token can't be read")
    func noTokenNoRequest() async throws {
        let transport = MockTransport()
        await #expect(throws: RaterError.self) {
            _ = try await makeClient(transport, reporter: UnavailableTokenStore()).fetchInbox()
        }
        #expect(transport.requestCount == 0)
    }
}

@Suite("Conversations: sending and the message queue")
struct ConversationServiceTests {

    @Test("a message written offline is queued, and replays once back online")
    func queuesOffline() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        let failing = MockTransport()
        failing.alwaysFails = URLError(.notConnectedToInternet)
        let message = pendingMessage()
        await #expect(throws: RaterError.self) {
            _ = try await makeService(failing, outbox: outbox).send(message)
        }
        #expect(await makeService(failing, outbox: outbox).pending(threadID: "fb_abc").map(\.id) == [message.id])

        let working = MockTransport([.init(status: 201, json: messageJSON)])
        await makeService(working, outbox: outbox).flush()
        #expect(await outbox.count == 0)

        // The replay reuses the original key, so a send that did land isn't posted twice.
        let body = try #require(working.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains(message.idempotencyKey))
    }

    @Test("a message the server refuses is not queued")
    func refusedIsDropped() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        let transport = MockTransport([.init(status: 404, json: #"{"error":{"code":"not_found","message":"No such thread."}}"#)])
        await #expect(throws: RaterError.self) {
            _ = try await makeService(transport, outbox: outbox).send(pendingMessage())
        }
        #expect(await outbox.count == 0)
    }

    @Test("deleting the history forgets the token and the queue")
    func deleteHistory() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }
        await outbox.enqueue(pendingMessage())

        let reporter = InMemoryReporterTokenStore("reporter-token-0123456789abcdefghijklmnop")
        let transport = MockTransport([.init(json: #"{"ok":true,"deleted":3}"#)])
        try await makeService(transport, outbox: outbox, reporter: reporter).deleteHistory()

        #expect(transport.requests.first?.httpMethod == "DELETE")
        #expect(await outbox.count == 0)
        #expect(reporter.token() != "reporter-token-0123456789abcdefghijklmnop")
    }

    @Test("a failed delete leaves the token alone")
    func failedDeleteKeepsToken() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        let reporter = InMemoryReporterTokenStore("reporter-token-0123456789abcdefghijklmnop")
        let transport = MockTransport()
        transport.alwaysFails = URLError(.notConnectedToInternet)
        await #expect(throws: RaterError.self) {
            try await makeService(transport, outbox: outbox, reporter: reporter).deleteHistory()
        }
        #expect(reporter.token() == "reporter-token-0123456789abcdefghijklmnop")
    }
}

@Suite("Conversations: reporter token")
struct ReporterTokenTests {

    @Test("generated tokens are 43 base64url characters, the shape the server accepts")
    func tokenShape() {
        let token = InMemoryReporterTokenStore.generateToken()
        #expect(token.count == 43)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(token != InMemoryReporterTokenStore.generateToken())
    }

    @Test("the token is stable until reset")
    func stableUntilReset() {
        let store = InMemoryReporterTokenStore()
        let first = store.token()
        #expect(store.token() == first)
        store.reset()
        #expect(store.token() != first)
    }
}

/// A Keychain that can't be read — the state before the first unlock after a reboot.
private struct UnavailableTokenStore: ReporterTokenStore {
    func token() -> String? { nil }
    func reset() {}
}
