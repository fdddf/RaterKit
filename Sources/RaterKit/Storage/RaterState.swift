import Foundation

/// All locally persisted state. Stored as a single JSON blob under one UserDefaults
/// key, so adding a field needs no migration and clearing everything is one removal.
public struct RaterState: Codable, Sendable, Equatable {
    /// When RaterKit first ran.
    public var installDate: Date
    /// Lifetime launch count.
    public var launchCount: Int
    /// Launch count per app version.
    public var launchCountByVersion: [String: Int]
    /// Running count of each named event.
    public var eventCounts: [String: Int]

    /// When the pre-prompt was last shown.
    public var lastPromptDate: Date?
    /// How the last prompt ended.
    public var lastPromptOutcome: String?
    /// How many pre-prompts have been shown in total.
    public var promptCount: Int
    /// How many were shown per app version.
    public var promptCountByVersion: [String: Int]

    /// The user tapped the positive button, so we assume they went on to rate.
    public var hasRated: Bool
    /// The user explicitly asked not to be prompted again.
    public var hasOptedOut: Bool

    /// The email used last time, prefilled on the next submission.
    public var lastEmail: String?

    public init(
        installDate: Date = Date(),
        launchCount: Int = 0,
        launchCountByVersion: [String: Int] = [:],
        eventCounts: [String: Int] = [:],
        lastPromptDate: Date? = nil,
        lastPromptOutcome: String? = nil,
        promptCount: Int = 0,
        promptCountByVersion: [String: Int] = [:],
        hasRated: Bool = false,
        hasOptedOut: Bool = false,
        lastEmail: String? = nil
    ) {
        self.installDate = installDate
        self.launchCount = launchCount
        self.launchCountByVersion = launchCountByVersion
        self.eventCounts = eventCounts
        self.lastPromptDate = lastPromptDate
        self.lastPromptOutcome = lastPromptOutcome
        self.promptCount = promptCount
        self.promptCountByVersion = promptCountByVersion
        self.hasRated = hasRated
        self.hasOptedOut = hasOptedOut
        self.lastEmail = lastEmail
    }
}
