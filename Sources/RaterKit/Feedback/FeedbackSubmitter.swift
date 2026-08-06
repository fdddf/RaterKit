import Foundation
import os

/// Runs the three-step submission: create, upload attachments, complete.
///
/// A failed attachment does not fail the feedback — the text landed in step one, so we
/// upload whatever screenshots we can and complete regardless. What the user wrote
/// matters far more than the pictures.
actor FeedbackSubmitter {
    private let client: RaterAPIClient
    private let outbox: Outbox
    private let isOfflineRetryEnabled: Bool
    private let logger = Logger(subsystem: "com.raterkit", category: "submit")

    init(client: RaterAPIClient, outbox: Outbox, isOfflineRetryEnabled: Bool) {
        self.client = client
        self.outbox = outbox
        self.isOfflineRetryEnabled = isOfflineRetryEnabled
    }

    /// Submits a feedback. If this throws and offline retry is on, it is already queued.
    @discardableResult
    func submit(_ draft: FeedbackDraft, device: DiagnosticsPayload) async throws -> String {
        let submission = PendingSubmission(
            idempotencyKey: draft.idempotencyKey,
            message: draft.message.trimmingCharacters(in: .whitespacesAndNewlines),
            category: draft.category,
            email: draft.email?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            metadata: draft.metadata,
            device: device,
            attachments: draft.attachments.map {
                .init(data: $0.data, contentType: $0.contentType)
            },
            queuedAt: Date(),
            attempts: 0
        )

        do {
            return try await send(submission)
        } catch {
            if isOfflineRetryEnabled, (error as? RaterError)?.isRetryable ?? true {
                await outbox.enqueue(submission)
            }
            throw error
        }
    }

    /// Replays the backlog. Called at launch and whenever the network comes back.
    func flushOutbox() async {
        let items = await outbox.pending()
        guard !items.isEmpty else { return }
        logger.debug("replaying \(items.count) queued submissions")

        for item in items {
            do {
                _ = try await send(item)
                await outbox.remove(item.idempotencyKey)
            } catch {
                // A 4xx means the entry itself is bad; retrying changes nothing, so drop it.
                if let raterError = error as? RaterError, !raterError.isRetryable {
                    await outbox.remove(item.idempotencyKey)
                    logger.notice("rejected by the server, dropping: \(item.idempotencyKey)")
                } else {
                    await outbox.recordAttempt(item)
                    // Still offline — leave the rest for the next pass.
                    break
                }
            }
        }
    }

    // MARK: - Private

    private func send(_ submission: PendingSubmission) async throws -> String {
        let created = try await client.createFeedback(
            FeedbackSubmissionBody(
                idempotencyKey: submission.idempotencyKey,
                message: submission.message,
                category: submission.category,
                email: submission.email,
                attachmentCount: submission.attachments.count,
                device: submission.device,
                metadata: submission.metadata.isEmpty ? nil : submission.metadata
            )
        )

        if let token = created.uploadToken {
            for (index, attachment) in submission.attachments.enumerated() {
                do {
                    try await client.uploadAttachment(
                        feedbackID: created.id, index: index, token: token,
                        data: attachment.data, contentType: attachment.contentType
                    )
                } catch {
                    // Skip a failed screenshot rather than sinking the whole feedback.
                    logger.notice("screenshot \(index) failed to upload: \(error.localizedDescription)")
                }
            }
        }

        try await client.completeFeedback(id: created.id)
        return created.id
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
