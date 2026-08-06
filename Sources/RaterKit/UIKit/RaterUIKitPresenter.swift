import SwiftUI
import UIKit

/// Presentation entry points for UIKit host apps.
///
/// `.raterPrompt()` needs a SwiftUI view tree to attach to; a pure UIKit app uses these
/// instead, which wrap the same two screens in a `UIHostingController` and present them.
@MainActor
public enum RaterUIKitPresenter {

    /// Shows the pre-prompt only if the rules pass. Returns whether it actually appeared.
    @discardableResult
    public static func presentPromptIfEligible(from presenter: UIViewController) async -> Bool {
        let decision = await Rater.shared.evaluate()
        guard decision.isEligible else { return false }

        await presentPrompt(from: presenter)
        return true
    }

    /// Shows the pre-prompt regardless of the rules.
    public static func presentPrompt(from presenter: UIViewController) async {
        let rater = Rater.shared
        await rater.presentPrompt()

        guard case .prompt(let copy) = rater.presentation else { return }

        // The overlay draws its own scrim, so the hosting controller must be presented
        // transparently or it would cover everything underneath.
        let host = UIHostingController(
            rootView: RatingPromptView(
                copy: copy,
                theme: rater.currentTheme,
                onPositive: { [weak presenter] in
                    presenter?.presentedViewController?.dismiss(animated: false)
                    rater.handlePositive()
                },
                onNegative: { [weak presenter] in
                    presenter?.presentedViewController?.dismiss(animated: false) {
                        Task { await presentFeedbackForm(from: presenter) }
                    }
                    rater.handleNegative()
                },
                onDismiss: { [weak presenter] optOut in
                    presenter?.presentedViewController?.dismiss(animated: false)
                    rater.handleDismiss(optOut: optOut)
                }
            )
        )
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve

        presenter.present(host, animated: false)
    }

    /// Opens the feedback form directly.
    public static func presentFeedbackForm(
        from presenter: UIViewController?,
        category: String? = nil
    ) async {
        guard let presenter else { return }

        let rater = Rater.shared
        let context = await rater.makeFeedbackContext(category: category)

        let host = UIHostingController(
            rootView: FeedbackFormView(
                context: context,
                theme: rater.currentTheme,
                onSubmit: { try await rater.submit($0) },
                onDismiss: { [weak presenter] in
                    presenter?.presentedViewController?.dismiss(animated: true)
                    rater.dismissFeedback()
                }
            )
        )
        presenter.present(host, animated: true)
    }
}
