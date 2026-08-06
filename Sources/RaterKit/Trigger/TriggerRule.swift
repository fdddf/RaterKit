import Foundation

/// One trigger rule. *Every* rule in `RaterConfiguration.rules` must pass before the
/// pre-prompt is shown.
///
/// Built-in rules are the static factories on `RaterRule`. For custom logic use
/// `.custom(_:_:)`, or conform to this protocol yourself.
public protocol TriggerRule: Sendable {
    /// Human-readable identifier. Shows up in `TriggerDecision.blockedBy` and in debug logs.
    var identifier: String { get }
    func evaluate(_ signals: TriggerSignals) -> Bool
}

/// A rule expressed as a closure. Every built-in rule is an instance of this.
public struct RaterRule: TriggerRule {
    public let identifier: String
    private let predicate: @Sendable (TriggerSignals) -> Bool

    public init(_ identifier: String, _ predicate: @escaping @Sendable (TriggerSignals) -> Bool) {
        self.identifier = identifier
        self.predicate = predicate
    }

    public func evaluate(_ signals: TriggerSignals) -> Bool {
        predicate(signals)
    }
}

// Written as an extension on `TriggerRule where Self == RaterRule` so the factories
// work with dot syntax inside array literals:
// `rules: [.launchCount(atLeast: 5), .cooldown(days: 30)]`.
public extension TriggerRule where Self == RaterRule {

    /// Installed for at least N days. The server's `min_days_since_install` overrides N.
    static func daysSinceInstall(atLeast days: Int) -> RaterRule {
        RaterRule("daysSinceInstall>=\(days)") { signals in
            signals.daysSinceInstall >= (signals.remoteRules?.minDaysSinceInstall ?? days)
        }
    }

    /// Launched at least N times. The server's `min_launch_count` overrides N.
    static func launchCount(atLeast count: Int) -> RaterRule {
        RaterRule("launchCount>=\(count)") { signals in
            signals.launchCount >= (signals.remoteRules?.minLaunchCount ?? count)
        }
    }

    /// Launched at least N times on the current version.
    static func launchCountThisVersion(atLeast count: Int) -> RaterRule {
        RaterRule("launchCountThisVersion>=\(count)") { $0.launchCountThisVersion >= count }
    }

    /// A named event happened at least N times — the most direct signal that someone
    /// is actually getting value out of the app.
    static func event(_ name: String, atLeast count: Int) -> RaterRule {
        RaterRule("event(\(name))>=\(count)") { $0.count(of: name) >= count }
    }

    /// All named events together total at least N. The server's `min_significant_events`
    /// overrides N.
    static func totalEvents(atLeast count: Int) -> RaterRule {
        RaterRule("totalEvents>=\(count)") { signals in
            signals.totalEventCount >= (signals.remoteRules?.minSignificantEvents ?? count)
        }
    }

    /// At least N days since the last prompt; passes if it has never been shown.
    /// The server's `cooldown_days` overrides N.
    static func cooldown(days: Int) -> RaterRule {
        RaterRule("cooldown>=\(days)d") { signals in
            guard let elapsed = signals.daysSinceLastPrompt else { return true }
            return elapsed >= (signals.remoteRules?.cooldownDays ?? days)
        }
    }

    /// At most N prompts per app version. The server's `max_prompts_per_version`
    /// overrides N.
    static func maxPromptsPerVersion(_ limit: Int) -> RaterRule {
        RaterRule("promptsThisVersion<\(limit)") { signals in
            signals.promptCountThisVersion < (signals.remoteRules?.maxPromptsPerVersion ?? limit)
        }
    }

    /// At most N prompts over the whole lifetime of the install.
    static func maxPromptsTotal(_ limit: Int) -> RaterRule {
        RaterRule("promptsTotal<\(limit)") { $0.promptCount < limit }
    }

    /// Stop bothering someone who already tapped the positive button.
    static var notAfterRated: RaterRule {
        RaterRule("notAfterRated") { !$0.hasRated }
    }

    /// Stop bothering someone who explicitly opted out.
    static var notAfterOptOut: RaterRule {
        RaterRule("notAfterOptOut") { !$0.hasOptedOut }
    }

    /// The server-side master switch. Keep this one — it's how you shut prompting off
    /// everywhere with a single click when something goes wrong in production.
    static var remoteEnabled: RaterRule {
        RaterRule("remoteEnabled") { $0.remoteEnabled }
    }

    /// A custom rule.
    ///
    /// ```swift
    /// .custom("isPaidUser") { _ in Subscription.shared.isActive }
    /// ```
    static func custom(
        _ identifier: String,
        _ predicate: @escaping @Sendable (TriggerSignals) -> Bool
    ) -> RaterRule {
        RaterRule(identifier, predicate)
    }

    /// Passes if any sub-rule passes — for conditions like "exported 3 times *or*
    /// has been around for 30 days".
    static func anyOf(_ rules: [any TriggerRule]) -> RaterRule {
        RaterRule("anyOf(\(rules.map(\.identifier).joined(separator: "|")))") { signals in
            rules.contains { $0.evaluate(signals) }
        }
    }

    /// Negates a rule.
    static func not(_ rule: any TriggerRule) -> RaterRule {
        RaterRule("not(\(rule.identifier))") { !rule.evaluate($0) }
    }

    /// Always passes. Handy for temporarily disabling a rule without restructuring
    /// the array.
    static var always: RaterRule {
        RaterRule("always") { _ in true }
    }
}
