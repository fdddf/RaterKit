import Foundation

/// The result of evaluating the rules. When it fails, it names which rules blocked —
/// far more useful than a bare Bool while you're tuning when to prompt.
public struct TriggerDecision: Sendable, Equatable {
    public let isEligible: Bool
    /// Identifiers of the rules that failed, in the order they were declared.
    public let blockedBy: [String]
    /// The snapshot that was evaluated.
    public let signals: TriggerSignals

    public var description: String {
        isEligible ? "eligible" : "blocked by \(blockedBy.joined(separator: ", "))"
    }
}

/// Runs the rules in order.
///
/// Deliberately does not short-circuit: even after the first failure it evaluates the
/// rest, so `blockedBy` lists every unmet condition at once instead of making you
/// iterate. Rules are pure functions, so the extra work is free.
public struct TriggerEngine: Sendable {
    public let rules: [any TriggerRule]

    public init(rules: [any TriggerRule]) {
        self.rules = rules
    }

    public func evaluate(_ signals: TriggerSignals) -> TriggerDecision {
        let blocked = rules.filter { !$0.evaluate(signals) }.map(\.identifier)
        return TriggerDecision(isEligible: blocked.isEmpty, blockedBy: blocked, signals: signals)
    }
}
