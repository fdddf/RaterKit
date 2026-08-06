import SwiftUI

public extension View {
    /// Mounts RaterKit's presentation host.
    ///
    /// Put it on the root view, normally the one inside `WindowGroup`:
    /// ```swift
    /// WindowGroup { ContentView().raterPrompt() }
    /// ```
    /// Everything raised by `promptIfEligible()`, `presentPrompt()` and
    /// `presentFeedbackForm()` is presented through it.
    func raterPrompt() -> some View {
        modifier(RaterHostModifier())
    }

    /// A binding-driven feedback form, for a standalone entry such as Settings → Feedback.
    ///
    /// It brings its own sheet and does not depend on `.raterPrompt()` being mounted on
    /// the root view, so a settings screen can use it on its own.
    func raterFeedbackSheet(isPresented: Binding<Bool>, category: String? = nil) -> some View {
        modifier(RaterFeedbackSheetModifier(isPresented: isPresented, category: category))
    }
}

/// Hosts the pre-prompt overlay and the feedback sheet.
struct RaterHostModifier: ViewModifier {
    @State private var rater = Rater.shared
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content
            // Prefer SwiftUI's own requestReview over hunting through connectedScenes —
            // more reliable with multiple windows and iPad split view.
            .onAppear {
                rater.reviewRequester = EnvironmentReviewRequester(action: requestReview)
            }
            .overlay {
                if case .prompt(let copy) = rater.presentation {
                    RatingPromptView(
                        copy: copy,
                        theme: rater.currentTheme,
                        onPositive: { rater.handlePositive() },
                        onNegative: { rater.handleNegative() },
                        onDismiss: { rater.handleDismiss(optOut: $0) }
                    )
                    .transition(.opacity)
                    .zIndex(999)
                }
            }
            .sheet(isPresented: isFeedbackPresented) {
                if case .feedback(let context) = rater.presentation {
                    FeedbackFormView(
                        context: context,
                        theme: rater.currentTheme,
                        onSubmit: { try await rater.submit($0) },
                        onDismiss: { rater.dismissFeedback() }
                    )
                }
            }
    }

    private var isFeedbackPresented: Binding<Bool> {
        Binding(
            get: { if case .feedback = rater.presentation { true } else { false } },
            set: { if !$0 { rater.dismissFeedback() } }
        )
    }
}

/// Standalone feedback entry point, with its own sheet.
struct RaterFeedbackSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let category: String?

    @State private var rater = Rater.shared
    @State private var context: FeedbackContext?

    func body(content: Content) -> some View {
        content
            .task(id: isPresented) {
                // Fetch config first and only then present, so the sheet doesn't flash
                // bundled copy before the server's copy replaces it.
                guard isPresented, context == nil else { return }
                context = await rater.makeFeedbackContext(category: category)
            }
            .sheet(item: $context) { context in
                FeedbackFormView(
                    context: context,
                    theme: rater.currentTheme,
                    onSubmit: { try await rater.submit($0) },
                    onDismiss: { self.context = nil }
                )
            }
            .onChange(of: context == nil) { _, dismissed in
                if dismissed { isPresented = false }
            }
    }
}
