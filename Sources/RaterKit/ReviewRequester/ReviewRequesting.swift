import StoreKit
import SwiftUI
import UIKit

/// Seam for triggering the system review prompt, so tests can record calls instead.
@MainActor
public protocol ReviewRequesting: Sendable {
    func requestReview() async
}

/// Default implementation, via StoreKit.
///
/// Note that the system throttles this prompt itself (at most three times a year, and
/// users can switch it off entirely in Settings), so calling it does not guarantee
/// anything appears. That's exactly why the pre-prompt exists: it spends this scarce
/// opportunity only on users who already said they're happy.
@MainActor
public struct StoreKitReviewRequester: ReviewRequesting {
    public init() {}

    public func requestReview() async {
        guard let scene = Self.activeScene() else { return }
        AppStore.requestReview(in: scene)
    }

    static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// Wraps SwiftUI's `requestReview` environment action.
///
/// Preferred whenever a view can supply it — SwiftUI picks the scene itself, which
/// beats guessing from `connectedScenes`.
@MainActor
struct EnvironmentReviewRequester: ReviewRequesting {
    let action: RequestReviewAction

    func requestReview() async {
        action()
    }
}

public extension Rater {
    /// Opens the App Store's "write a review" page directly.
    ///
    /// Unlike the system prompt this always leaves the app, so it belongs on a
    /// deliberate entry point such as a settings row — not as a substitute for
    /// `presentPrompt()`.
    @discardableResult
    func openWriteReviewPage() -> Bool {
        guard let appStoreID = resolvedAppStoreID,
              let url = URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
        else { return false }

        UIApplication.shared.open(url)
        return true
    }
}
