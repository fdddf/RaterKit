import Foundation

/// Everything that can happen along the flow. Subscribe via `Rater.shared.events`
/// to feed your own analytics.
public enum RaterOutcome: Sendable, Equatable {
    /// The pre-prompt was shown.
    case promptShown
    /// The user tapped the positive button; the system review prompt follows.
    case ratedPositive
    /// The user tapped the negative button; the feedback form follows.
    case ratedNegative
    /// The user tapped "maybe later" or tapped outside the card.
    case promptDismissed
    /// The user chose never to be asked again.
    case optedOut
    /// The feedback form was opened.
    case feedbackOpened
    /// Feedback was submitted successfully.
    case feedbackSubmitted(id: String)
    /// Submission failed; already queued if offline retry is enabled.
    case feedbackFailed(queued: Bool)
    /// No prompt was shown because the rules did not pass.
    case promptSuppressed(blockedBy: [String])

    /// Telemetry kind reported to the server; nil for events we don't report.
    var telemetryKind: String? {
        switch self {
        case .promptShown: "shown"
        case .ratedPositive: "positive"
        case .ratedNegative: "negative"
        case .promptDismissed, .optedOut: "dismissed"
        case .feedbackSubmitted: "submitted"
        case .feedbackOpened, .feedbackFailed, .promptSuppressed: nil
        }
    }
}
