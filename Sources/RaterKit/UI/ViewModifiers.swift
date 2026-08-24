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

    /// A binding-driven pre-prompt, for a deliberate "Rate this app" row on a screen
    /// that is itself presented as a sheet.
    ///
    /// `.raterPrompt()` draws its overlay on the root view, which is *underneath* any
    /// sheet the app has open — a prompt raised from inside one is drawn where nobody
    /// can see it, and only turns up once the sheet is gone. This one presents itself,
    /// above the screen it is attached to, and brings its own feedback form for the
    /// negative answer:
    /// ```swift
    /// Button("Rate this app") { showsRating = true }
    /// …
    /// .raterRatingPrompt(isPresented: $showsRating)
    /// ```
    func raterRatingPrompt(isPresented: Binding<Bool>) -> some View {
        modifier(RaterPromptSheetModifier(isPresented: isPresented))
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

/// Standalone pre-prompt, with its own presentation.
///
/// The prompt draws its own scrim, so the cover is presented transparently and with the
/// system's slide left out — what animates is the card's own fade and scale.
struct RaterPromptSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let category: String?

    @State private var rater = Rater.shared
    @State private var copy: RaterCopy?
    @State private var showsFeedback = false
    @State private var wantsFeedback = false
    @Environment(\.requestReview) private var requestReview

    init(isPresented: Binding<Bool>, category: String? = nil) {
        _isPresented = isPresented
        self.category = category
    }

    func body(content: Content) -> some View {
        content
            .onAppear { rater.reviewRequester = EnvironmentReviewRequester(action: requestReview) }
            .task(id: isPresented) {
                // Fetch config first and only then present, so the card doesn't flash
                // bundled copy before the server's copy replaces it.
                guard isPresented, copy == nil else { return }
                let fetched = await rater.preparePrompt()
                // The card animates itself in; the cover it rides on should not slide.
                withoutPresentationAnimation { copy = fetched }
            }
            .fullScreenCover(isPresented: isCardPresented, onDismiss: openFeedbackIfAsked) {
                if let copy {
                    RatingPromptView(
                        copy: copy,
                        theme: rater.currentTheme,
                        onPositive: {
                            dismissCard()
                            rater.handlePositive()
                        },
                        onNegative: {
                            // The form is opened from the cover's dismissal rather than
                            // here: a sheet raised while the cover is still on its way
                            // out never arrives.
                            wantsFeedback = true
                            dismissCard()
                            rater.recordNegative()
                        },
                        onDismiss: { optOut in
                            dismissCard()
                            rater.handleDismiss(optOut: optOut)
                        }
                    )
                    .presentationBackground(.clear)
                }
            }
            .raterFeedbackSheet(isPresented: $showsFeedback, category: category)
    }

    private var isCardPresented: Binding<Bool> {
        Binding(get: { copy != nil }, set: { if !$0 { dismissCard() } })
    }

    private func dismissCard() {
        // The card has already played its own exit by now, so the cover goes without
        // one of its own.
        withoutPresentationAnimation { copy = nil }
        isPresented = false
    }

    private func withoutPresentationAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    private func openFeedbackIfAsked() {
        guard wantsFeedback else { return }
        wantsFeedback = false
        showsFeedback = true
    }
}
