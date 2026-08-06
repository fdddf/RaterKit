import Foundation

/// Everything a rule can see when it is evaluated. An immutable snapshot, so no
/// rule ever observes state changing mid-evaluation.
public struct TriggerSignals: Sendable, Equatable {
    /// The moment of evaluation. Tests can pin this.
    public let now: Date

    public let installDate: Date
    public let launchCount: Int
    public let launchCountThisVersion: Int
    public let eventCounts: [String: Int]

    /// Current app version (`CFBundleShortVersionString`).
    public let appVersion: String

    public let lastPromptDate: Date?
    public let promptCount: Int
    public let promptCountThisVersion: Int
    public let hasRated: Bool
    public let hasOptedOut: Bool

    /// Whether the server has prompting enabled for this app. Treated as true when
    /// config can't be fetched, so a server outage doesn't silence the prompt forever.
    public let remoteEnabled: Bool
    /// Thresholds pushed down by the server. Built-in rules prefer these; the numbers
    /// baked into the client are only defaults.
    public let remoteRules: RemoteRules?

    public init(
        now: Date = Date(),
        installDate: Date,
        launchCount: Int,
        launchCountThisVersion: Int,
        eventCounts: [String: Int],
        appVersion: String,
        lastPromptDate: Date? = nil,
        promptCount: Int = 0,
        promptCountThisVersion: Int = 0,
        hasRated: Bool = false,
        hasOptedOut: Bool = false,
        remoteEnabled: Bool = true,
        remoteRules: RemoteRules? = nil
    ) {
        self.now = now
        self.installDate = installDate
        self.launchCount = launchCount
        self.launchCountThisVersion = launchCountThisVersion
        self.eventCounts = eventCounts
        self.appVersion = appVersion
        self.lastPromptDate = lastPromptDate
        self.promptCount = promptCount
        self.promptCountThisVersion = promptCountThisVersion
        self.hasRated = hasRated
        self.hasOptedOut = hasOptedOut
        self.remoteEnabled = remoteEnabled
        self.remoteRules = remoteRules
    }

    /// Whole calendar days since install.
    public var daysSinceInstall: Int {
        Calendar.current.dateComponents([.day], from: installDate, to: now).day ?? 0
    }

    /// Whole calendar days since the last prompt; nil if it has never been shown.
    public var daysSinceLastPrompt: Int? {
        guard let lastPromptDate else { return nil }
        return Calendar.current.dateComponents([.day], from: lastPromptDate, to: now).day ?? 0
    }

    /// How many times a named event has occurred.
    public func count(of event: String) -> Int {
        eventCounts[event] ?? 0
    }

    /// Sum of every named event.
    public var totalEventCount: Int {
        eventCounts.values.reduce(0, +)
    }
}

/// Threshold overrides the server can push down, so when to prompt is tunable
/// without shipping a build.
public struct RemoteRules: Sendable, Equatable, Codable {
    public var minDaysSinceInstall: Int?
    public var minLaunchCount: Int?
    public var minSignificantEvents: Int?
    public var cooldownDays: Int?
    public var maxPromptsPerVersion: Int?

    public init(
        minDaysSinceInstall: Int? = nil,
        minLaunchCount: Int? = nil,
        minSignificantEvents: Int? = nil,
        cooldownDays: Int? = nil,
        maxPromptsPerVersion: Int? = nil
    ) {
        self.minDaysSinceInstall = minDaysSinceInstall
        self.minLaunchCount = minLaunchCount
        self.minSignificantEvents = minSignificantEvents
        self.cooldownDays = cooldownDays
        self.maxPromptsPerVersion = maxPromptsPerVersion
    }

    private enum CodingKeys: String, CodingKey {
        case minDaysSinceInstall = "min_days_since_install"
        case minLaunchCount = "min_launch_count"
        case minSignificantEvents = "min_significant_events"
        case cooldownDays = "cooldown_days"
        case maxPromptsPerVersion = "max_prompts_per_version"
    }
}
