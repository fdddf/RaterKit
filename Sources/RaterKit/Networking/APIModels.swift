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
        var positiveLabel: String
        var negativeLabel: String
        var laterLabel: String

        enum CodingKeys: String, CodingKey {
            case title, message
            case positiveLabel = "positive_label"
            case negativeLabel = "negative_label"
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
