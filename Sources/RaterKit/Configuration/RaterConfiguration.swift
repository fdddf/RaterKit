import Foundation

/// Everything RaterKit can be configured with. Only the first three are required.
public struct RaterConfiguration: Sendable {
    // MARK: Required

    /// Root URL of the Worker, e.g. `https://rater-collector.you.workers.dev`.
    public var endpoint: URL
    /// The app id registered on the server.
    public var appID: String
    /// The API key issued by the server (`rtr_pub_…`).
    public var apiKey: String

    // MARK: Optional

    /// Numeric App Store id, used to fall back to the "write a review" page when
    /// the system review prompt is unavailable.
    public var appStoreID: String?

    /// Trigger rules. *All* of them must pass before the pre-prompt is shown;
    /// entry points other than `promptIfEligible()` bypass them.
    ///
    /// The default set means: installed at least 3 days, launched at least 5 times,
    /// not already prompted on this version, at least 60 days since the last prompt,
    /// never again once rated or opted out, and the server can shut it off at any time.
    public var rules: [any TriggerRule]

    /// Which UserDefaults suite local state lives in. Pass an App Group to share
    /// launch counts with extensions.
    public var userDefaultsSuiteName: String?

    /// How many screenshots a feedback may carry.
    public var maxAttachments: Int
    /// Pixel cap on the long edge of a screenshot after downscaling.
    public var attachmentMaxDimension: CGFloat
    /// JPEG quality used for screenshots.
    public var attachmentCompressionQuality: CGFloat

    /// How long remote copy stays fresh locally. Only after it expires does a
    /// request actually go out — and it goes out with an ETag.
    public var configCacheTTL: TimeInterval

    /// Whether to report prompt funnel telemetry. It carries no user identifiers.
    public var isTelemetryEnabled: Bool
    /// Whether to attach device and version info to feedback. Off means only what
    /// the user typed is sent.
    public var collectsDiagnostics: Bool
    /// Whether failed submissions are persisted and retried on the next launch.
    public var isOfflineRetryEnabled: Bool

    /// Whether the feedback form requires an email. The server config overrides this.
    public var requiresEmail: Bool

    /// Copy used when server copy is unavailable — first launch, or offline.
    public var fallbackCopy: RaterCopy

    /// Appearance.
    public var theme: RaterTheme

    /// Logs how each rule evaluated. Handy while tuning when to prompt.
    public var isDebugLoggingEnabled: Bool

    public init(
        endpoint: URL,
        appID: String,
        apiKey: String,
        appStoreID: String? = nil,
        rules: [any TriggerRule] = RaterConfiguration.defaultRules,
        userDefaultsSuiteName: String? = nil,
        maxAttachments: Int = 3,
        attachmentMaxDimension: CGFloat = 1600,
        attachmentCompressionQuality: CGFloat = 0.7,
        configCacheTTL: TimeInterval = 6 * 3600,
        isTelemetryEnabled: Bool = true,
        collectsDiagnostics: Bool = true,
        isOfflineRetryEnabled: Bool = true,
        requiresEmail: Bool = false,
        fallbackCopy: RaterCopy = .default,
        theme: RaterTheme = .init(),
        isDebugLoggingEnabled: Bool = false
    ) {
        self.endpoint = endpoint
        self.appID = appID
        self.apiKey = apiKey
        self.appStoreID = appStoreID
        self.rules = rules
        self.userDefaultsSuiteName = userDefaultsSuiteName
        self.maxAttachments = maxAttachments
        self.attachmentMaxDimension = attachmentMaxDimension
        self.attachmentCompressionQuality = attachmentCompressionQuality
        self.configCacheTTL = configCacheTTL
        self.isTelemetryEnabled = isTelemetryEnabled
        self.collectsDiagnostics = collectsDiagnostics
        self.isOfflineRetryEnabled = isOfflineRetryEnabled
        self.requiresEmail = requiresEmail
        self.fallbackCopy = fallbackCopy
        self.theme = theme
        self.isDebugLoggingEnabled = isDebugLoggingEnabled
    }

    /// A conservative default set, fine to ship as-is for most utility apps.
    public static var defaultRules: [any TriggerRule] {
        [
            .notAfterRated,
            .notAfterOptOut,
            .remoteEnabled,
            .daysSinceInstall(atLeast: 3),
            .launchCount(atLeast: 5),
            .maxPromptsPerVersion(1),
            .cooldown(days: 60),
        ]
    }
}

/// Copy for the pre-prompt and the feedback form. Server-provided copy overrides it.
public struct RaterCopy: Sendable, Equatable, Codable {
    public var promptTitle: String
    public var promptMessage: String
    public var positiveLabel: String
    public var negativeLabel: String
    public var laterLabel: String
    public var feedbackTitle: String?
    public var feedbackMessage: String?
    public var categories: [FeedbackCategory]

    public init(
        promptTitle: String,
        promptMessage: String,
        positiveLabel: String,
        negativeLabel: String,
        laterLabel: String,
        feedbackTitle: String? = nil,
        feedbackMessage: String? = nil,
        categories: [FeedbackCategory] = []
    ) {
        self.promptTitle = promptTitle
        self.promptMessage = promptMessage
        self.positiveLabel = positiveLabel
        self.negativeLabel = negativeLabel
        self.laterLabel = laterLabel
        self.feedbackTitle = feedbackTitle
        self.feedbackMessage = feedbackMessage
        self.categories = categories
    }

    /// Resolved through the bundled String Catalog (en / zh-Hans / ja / de), so even
    /// offline the user sees their own language.
    public static var `default`: RaterCopy {
        RaterCopy(
            promptTitle: String(localized: "rater.prompt.title",
                                defaultValue: "Enjoying this app?", bundle: .module),
            promptMessage: String(localized: "rater.prompt.message",
                                  defaultValue: "Your opinion matters to us — it only takes a few seconds.",
                                  bundle: .module),
            positiveLabel: String(localized: "rater.prompt.positive",
                                  defaultValue: "I like it", bundle: .module),
            negativeLabel: String(localized: "rater.prompt.negative",
                                  defaultValue: "Not quite", bundle: .module),
            laterLabel: String(localized: "rater.prompt.later",
                               defaultValue: "Maybe later", bundle: .module),
            categories: [
                .init(id: "bug", label: String(localized: "rater.category.bug",
                                               defaultValue: "Something's broken", bundle: .module)),
                .init(id: "feature", label: String(localized: "rater.category.feature",
                                                   defaultValue: "Feature request", bundle: .module)),
                .init(id: "other", label: String(localized: "rater.category.other",
                                                 defaultValue: "Something else", bundle: .module)),
            ]
        )
    }
}

public struct FeedbackCategory: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}
