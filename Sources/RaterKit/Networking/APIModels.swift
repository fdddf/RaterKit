import Foundation

// The server speaks snake_case. Every type spells out its CodingKeys instead of
// using `.convertFromSnakeCase` — an explicit mapping breaks the build when a field
// is renamed, whereas a key strategy silently decodes nothing.

/// Response of `GET /v1/config`.
struct RemoteConfigResponse: Codable, Sendable, Equatable {
    var enabled: Bool
    var variant: String
    var appStoreID: String?
    var prompt: Prompt?
    var feedback: Feedback?
    var rules: RemoteRules?

    struct Prompt: Codable, Sendable, Equatable {
        var title: String
        var message: String
        var rateLabel: String
        var feedbackLabel: String
        var laterLabel: String

        enum CodingKeys: String, CodingKey {
            case title, message
            // The wire names predate the Rate / Feedback split and are kept so every
            // client already in the field keeps decoding the same response.
            case rateLabel = "positive_label"
            case feedbackLabel = "negative_label"
            case laterLabel = "later_label"
        }
    }

    struct Feedback: Codable, Sendable, Equatable {
        var title: String?
        var message: String?
        var categories: [FeedbackCategory]
        var emailRequired: Bool

        enum CodingKeys: String, CodingKey {
            case title, message, categories
            case emailRequired = "email_required"
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, variant, prompt, feedback, rules
        case appStoreID = "app_store_id"
    }
}

/// Request body of `POST /v1/feedback`.
struct FeedbackSubmissionBody: Encodable, Sendable {
    var idempotencyKey: String
    var message: String
    var category: String?
    var email: String?
    var attachmentCount: Int
    var device: DiagnosticsPayload
    var metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case message, category, email, device, metadata
        case idempotencyKey = "idempotency_key"
        case attachmentCount = "attachment_count"
    }
}

/// Response of `POST /v1/feedback`.
struct FeedbackSubmissionResponse: Decodable, Sendable {
    var id: String
    var uploadToken: String?
    var expiresAt: Int
    var maxAttachmentBytes: Int
    var duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case id, duplicate
        case uploadToken = "upload_token"
        case expiresAt = "expires_at"
        case maxAttachmentBytes = "max_attachment_bytes"
    }
}

/// Request body of `POST /v1/telemetry`.
struct TelemetryBody: Encodable, Sendable {
    var events: [Event]

    struct Event: Encodable, Sendable {
        var kind: String
        var appVersion: String?
        var variant: String?
        var locale: String?

        enum CodingKeys: String, CodingKey {
            case kind, variant, locale
            case appVersion = "app_version"
        }
    }
}

/// The server's uniform error envelope.
struct APIErrorBody: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        var code: String
        var message: String
    }
    var error: Detail
}

// MARK: - Conversations

/// One thread in `GET /v1/threads`: a feedback this device sent, and where it stands.
struct ThreadSummary: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    var createdAt: Date
    var lastMessageAt: Date
    /// `open` or `resolved`. Anything else reads as open.
    var status: String
    var category: String?
    /// The latest message, cut short by the server.
    var preview: String
    /// Who spoke last: `user` or `admin`.
    var lastAuthor: String
    var unreadCount: Int

    var isResolved: Bool { status == "resolved" }

    enum CodingKeys: String, CodingKey {
        case id, status, category, preview
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
        case lastAuthor = "last_author"
        case unreadCount = "unread_count"
    }
}

/// Response of `GET /v1/threads`.
struct ThreadPage: Decodable, Sendable {
    var items: [ThreadSummary]
    /// Pass back as `before` for the next page; nil on the last one.
    var nextBefore: Int64?

    enum CodingKeys: String, CodingKey {
        case items
        case nextBefore = "next_before"
    }
}

/// The header of `GET /v1/threads/:id` — the summary plus the opening message in full.
struct ThreadDetail: Decodable, Sendable, Equatable {
    var summary: ThreadSummary
    var message: String
    var attachmentCount: Int

    enum CodingKeys: String, CodingKey {
        case message
        case attachmentCount = "attachment_count"
    }

    init(from decoder: any Decoder) throws {
        // The server flattens the summary fields into the same object.
        summary = try ThreadSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        attachmentCount = try container.decode(Int.self, forKey: .attachmentCount)
    }
}

/// One message after the feedback itself.
struct ThreadMessage: Decodable, Sendable, Equatable, Identifiable {
    /// Ordering, and the cursor for `after=` and the read marker.
    var seq: Int64
    var id: String
    /// `user` or `admin`.
    var author: String
    var body: String
    var createdAt: Date

    var isFromUser: Bool { author == "user" }

    enum CodingKeys: String, CodingKey {
        case seq, id, author, body
        case createdAt = "created_at"
    }
}

/// Response of `GET /v1/threads/:id`.
struct ThreadResponse: Decodable, Sendable {
    var thread: ThreadDetail
    var messages: [ThreadMessage]
}

/// Request body of `POST /v1/threads/:id/messages`.
struct ThreadMessageBody: Encodable, Sendable {
    var idempotencyKey: String
    var body: String

    enum CodingKeys: String, CodingKey {
        case body
        case idempotencyKey = "idempotency_key"
    }
}

/// Response of `POST /v1/threads/:id/messages`.
struct ThreadMessageResponse: Decodable, Sendable {
    var message: ThreadMessage
}

/// Response of `GET /v1/inbox`.
struct InboxResponse: Decodable, Sendable, Equatable {
    var unreadCount: Int
    var unreadThreads: Int

    enum CodingKeys: String, CodingKey {
        case unreadCount = "unread_count"
        case unreadThreads = "unread_threads"
    }
}
