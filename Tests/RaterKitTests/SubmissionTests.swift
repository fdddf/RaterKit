import Foundation
import Testing
import UIKit
@testable import RaterKit

private let endpoint = URL(string: "https://example.test")!

private let createdJSON = """
{"id":"fb_abc","upload_token":"tok_xyz","expires_at":1700000900,
 "max_attachment_bytes":5242880,"duplicate":false}
"""

private func makeSubmitter(
    _ transport: MockTransport,
    outbox: Outbox,
    offlineRetry: Bool = true
) -> FeedbackSubmitter {
    FeedbackSubmitter(
        client: RaterAPIClient(endpoint: endpoint, apiKey: "k", transport: transport),
        outbox: outbox,
        isOfflineRetryEnabled: offlineRetry
    )
}

/// A separate queue directory per test, so they cannot interfere with each other.
private func makeOutbox() -> Outbox {
    Outbox(appID: "test-\(UUID().uuidString)")
}

@Suite("Three-step submission")
struct SubmissionTests {

    @Test("with no attachments it sends only create and complete")
    func submitWithoutAttachments() async throws {
        let transport = MockTransport([
            .init(status: 201, json: #"{"id":"fb_abc","upload_token":null,"expires_at":0,"max_attachment_bytes":5242880,"duplicate":false}"#),
            .init(),
        ])
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        var draft = FeedbackDraft()
        draft.message = "long enough to submit"
        let id = try await makeSubmitter(transport, outbox: outbox)
            .submit(draft, device: DiagnosticsPayload())

        #expect(id == "fb_abc")
        #expect(transport.requestCount == 2)
        #expect(transport.requests(matching: "attachments").isEmpty)
    }

    @Test("uploads every attachment in order")
    func submitWithAttachments() async throws {
        let transport = MockTransport([
            .init(status: 201, json: createdJSON),
            .init(), .init(),   // two screenshots
            .init(),            // complete
        ])
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        var draft = FeedbackDraft()
        draft.message = "feedback with screenshots"
        draft.attachments = [makeAttachment(), makeAttachment()]

        _ = try await makeSubmitter(transport, outbox: outbox)
            .submit(draft, device: DiagnosticsPayload())

        let uploads = transport.requests(matching: "attachments")
        #expect(uploads.count == 2)
        #expect(uploads[0].url?.path().hasSuffix("/0") == true)
        #expect(uploads[1].url?.path().hasSuffix("/1") == true)
        // complete must come after the attachments
        #expect(transport.requests.last?.url?.path().hasSuffix("/complete") == true)
    }

    @Test("one failed screenshot does not sink the feedback — text matters more")
    func attachmentFailureDoesNotFailSubmission() async throws {
        let transport = MockTransport([
            .init(status: 201, json: createdJSON),
            .init(status: 413, json: #"{"error":{"code":"too_large","message":"too large"}}"#),
            .init(),  // the second one succeeds
            .init(),  // complete
        ])
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        var draft = FeedbackDraft()
        draft.message = "one screenshot will fail"
        draft.attachments = [makeAttachment(), makeAttachment()]

        let id = try await makeSubmitter(transport, outbox: outbox)
            .submit(draft, device: DiagnosticsPayload())

        #expect(id == "fb_abc")
        #expect(await outbox.count == 0, "the feedback succeeded, so nothing should be queued")
    }
}

@Suite("Offline retry queue")
struct OutboxTests {

    @Test("persists the feedback when the network fails")
    func queuesOnNetworkFailure() async throws {
        let transport = MockTransport()
        transport.alwaysFails = URLError(.notConnectedToInternet)
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        var draft = FeedbackDraft()
        draft.message = "submitted while offline"

        await #expect(throws: RaterError.self) {
            _ = try await makeSubmitter(transport, outbox: outbox)
                .submit(draft, device: DiagnosticsPayload())
        }

        let pending = await outbox.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.message == "submitted while offline")
        #expect(pending.first?.idempotencyKey == draft.idempotencyKey)
    }

    @Test("nothing is queued when offline retry is off")
    func respectsDisabledFlag() async throws {
        let transport = MockTransport()
        transport.alwaysFails = URLError(.notConnectedToInternet)
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        var draft = FeedbackDraft()
        draft.message = "should not be queued"

        await #expect(throws: RaterError.self) {
            _ = try await makeSubmitter(transport, outbox: outbox, offlineRetry: false)
                .submit(draft, device: DiagnosticsPayload())
        }
        #expect(await outbox.count == 0)
    }

    @Test("replays and drains the queue once back online")
    func flushesWhenBackOnline() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        // Submit one while offline
        let failing = MockTransport()
        failing.alwaysFails = URLError(.notConnectedToInternet)
        var draft = FeedbackDraft()
        draft.message = "written with no connection"
        _ = try? await makeSubmitter(failing, outbox: outbox)
            .submit(draft, device: DiagnosticsPayload())
        #expect(await outbox.count == 1)

        // Network is back
        let working = MockTransport([.init(status: 201, json: createdJSON), .init()])
        await makeSubmitter(working, outbox: outbox).flushOutbox()

        #expect(await outbox.count == 0)
        #expect(working.requestCount == 2)
    }

    @Test("a replay reuses the original idempotency key so the server can dedupe")
    func replayKeepsIdempotencyKey() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        let failing = MockTransport()
        failing.alwaysFails = URLError(.notConnectedToInternet)
        var draft = FeedbackDraft()
        draft.message = "this one will be replayed"
        let originalKey = draft.idempotencyKey
        _ = try? await makeSubmitter(failing, outbox: outbox)
            .submit(draft, device: DiagnosticsPayload())

        let working = MockTransport([.init(status: 201, json: createdJSON), .init()])
        await makeSubmitter(working, outbox: outbox).flushOutbox()

        let body = try #require(working.requests.first?.httpBody)
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json.contains(originalKey))
    }

    @Test("a server-rejected feedback is dropped rather than retried forever")
    func discardsRejectedSubmissions() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        let failing = MockTransport()
        failing.alwaysFails = URLError(.notConnectedToInternet)
        var draft = FeedbackDraft()
        draft.message = "this one will be rejected"
        _ = try? await makeSubmitter(failing, outbox: outbox)
            .submit(draft, device: DiagnosticsPayload())

        // The replay gets a 400
        let rejecting = MockTransport([
            .init(status: 400, json: #"{"error":{"code":"bad_request","message":"content not allowed"}}"#)
        ])
        await makeSubmitter(rejecting, outbox: outbox).flushOutbox()

        #expect(await outbox.count == 0, "a 4xx should be dropped, not retried forever")
    }

    @Test("re-queuing the same feedback does not pile up")
    func deduplicatesByKey() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        let submission = PendingSubmission(
            idempotencyKey: "same-key", message: "the same one", category: nil, email: nil,
            metadata: [:], device: DiagnosticsPayload(), attachments: [],
            queuedAt: Date(), attempts: 0
        )
        await outbox.enqueue(submission)
        await outbox.enqueue(submission)

        #expect(await outbox.count == 1)
    }

    @Test("gives up on an entry once the retry cap is hit")
    func givesUpAfterMaxAttempts() async throws {
        let outbox = makeOutbox()
        defer { Task { await outbox.clear() } }

        var submission = PendingSubmission(
            idempotencyKey: "doomed", message: "will never go through", category: nil, email: nil,
            metadata: [:], device: DiagnosticsPayload(), attachments: [],
            queuedAt: Date(), attempts: 0
        )
        await outbox.enqueue(submission)

        var abandoned = false
        for _ in 0..<10 {
            let current = await outbox.pending().first
            guard let current else { break }
            submission = current
            abandoned = await outbox.recordAttempt(submission)
            if abandoned { break }
        }

        #expect(abandoned)
        #expect(await outbox.count == 0)
    }
}

/// UIGraphicsImageRenderer is main-thread only, so the whole suite runs on the main actor.
@Suite("Screenshot compression")
@MainActor
struct AttachmentTests {

    @Test("large images are scaled within the long-edge cap")
    func downscalesLargeImages() throws {
        let big = makeImage(width: 3000, height: 2000)
        let attachment = try RaterKit.Attachment.make(from: big, maxDimension: 800)

        let decoded = try #require(UIImage(data: attachment.data))
        #expect(max(decoded.size.width, decoded.size.height) <= 800)
        #expect(attachment.contentType == "image/jpeg")
    }

    @Test("small images are not upscaled")
    func doesNotUpscale() throws {
        let small = makeImage(width: 100, height: 100)
        let attachment = try RaterKit.Attachment.make(from: small, maxDimension: 1600)

        let decoded = try #require(UIImage(data: attachment.data))
        #expect(decoded.size.width == 100)
    }

    @Test("scaling preserves the aspect ratio")
    func preservesAspectRatio() throws {
        let wide = makeImage(width: 2000, height: 1000)
        let attachment = try RaterKit.Attachment.make(from: wide, maxDimension: 500)

        let decoded = try #require(UIImage(data: attachment.data))
        #expect(abs(decoded.size.width / decoded.size.height - 2.0) < 0.02)
    }

    @Test("output fits inside the server's 5 MB cap")
    func staysUnderServerLimit() throws {
        let huge = makeImage(width: 4000, height: 3000)
        let attachment = try RaterKit.Attachment.make(from: huge, maxDimension: 1600, quality: 0.7)
        #expect(attachment.byteCount < 5 * 1024 * 1024)
    }

    @Test("a thumbnail is produced for the form preview")
    func generatesThumbnail() throws {
        let attachment = try RaterKit.Attachment.make(from: makeImage(width: 2000, height: 2000))
        let thumb = try #require(attachment.thumbnail)
        #expect(thumb.count < attachment.data.count)
    }

    @Test("non-image data throws")
    func rejectsNonImageData() {
        #expect(throws: RaterError.attachmentEncodingFailed) {
            _ = try RaterKit.Attachment.make(fromImageData: Data("not an image".utf8))
        }
    }
}

// MARK: - Helpers

@MainActor
private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        UIColor.systemPink.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    }
}

private func makeAttachment() -> RaterKit.Attachment {
    RaterKit.Attachment(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), contentType: "image/jpeg", thumbnail: nil)
}
