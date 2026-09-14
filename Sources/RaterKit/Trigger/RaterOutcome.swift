import Foundation

/// Everything that can happen along the flow. Subscribe via `Rater.shared.events`
/// to feed your own analytics.
public enum RaterOutcome: Sendable, Equatable {
    /// The pre-prompt was shown.
    case promptShown
    /// The user tapped Rate; the App Store review page follows.
    case rateChosen
    /// The user tapped Feedback; the feedback form follows.
    case feedbackChosen
    /// The user tapped the close button or outside the card.
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
        // The server's telemetry kinds keep their original names.
        case .rateChosen: "positive"
        case .feedbackChosen: "negative"
        case .promptDismissed, .optedOut: "dismissed"
        case .feedbackSubmitted: "submitted"
        case .feedbackOpened, .feedbackFailed, .promptSuppressed: nil
        }
    }
}
