import Foundation

/// One feedback as filled in by the user.
public struct FeedbackDraft: Sendable, Equatable {
    /// Generated client-side; the server dedupes on it. Stays fixed for the whole
    /// retry lifetime of this submission.
    public var idempotencyKey: String
    public var message: String
    public var category: String?
    public var email: String?
    public var attachments: [Attachment]
    /// Extra key/values contributed by the host app.
    public var metadata: [String: String]

    public init(
        idempotencyKey: String = UUID().uuidString,
        message: String = "",
        category: String? = nil,
        email: String? = nil,
        attachments: [Attachment] = [],
        metadata: [String: String] = [:]
    ) {
        self.idempotencyKey = idempotencyKey
        self.message = message
        self.category = category
        self.email = email
        self.attachments = attachments
        self.metadata = metadata
    }

    /// At least 4 non-whitespace characters — matching the server's validation so the
    /// user finds out before tapping send, not after.
    public var isMessageValid: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
    }

    public var isEmailValid: Bool {
        guard let email, !email.isEmpty else { return true }
        return FeedbackDraft.isValidEmail(email)
    }

    /// Whether this can be submitted. `emailRequired` comes from the server config.
    public func canSubmit(emailRequired: Bool) -> Bool {
        guard isMessageValid, isEmailValid else { return false }
        if emailRequired {
            guard let email, !email.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        }
        return true
    }

    /// A good-enough shape check: non-empty local part and domain, a dot in the domain,
    /// no whitespace. Real validation means sending mail; this only catches typos.
    static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return true
    }
}
