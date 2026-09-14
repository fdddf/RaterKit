import SwiftUI

/// The pre-prompt.
///
/// Offers both ways to be heard — rate on the App Store, or send feedback — side by side,
/// to everyone. It deliberately never routes only one kind of answer to the App Store:
/// filtering who gets to rate is review gating, which App Review rejects under
/// Guideline 5.6.1.
///
/// Drawn as an overlay rather than a system `alert` for two reasons: the copy has to
/// follow server config and the host's theme, and tapping Feedback needs to flow
/// straight into the feedback form — an alert-to-sheet handoff flickers.
struct RatingPromptView: View {
    let copy: RaterCopy
    let theme: RaterTheme
    let onRate: () -> Void
    let onFeedback: () -> Void
    let onDismiss: (_ optOut: Bool) -> Void

    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
                .opacity(isVisible ? theme.scrimOpacity : 0)
                .ignoresSafeArea()
                .onTapGesture { close { onDismiss(false) } }
                .accessibilityHidden(true)

            card
                .scaleEffect(isVisible ? 1 : 0.92)
                .opacity(isVisible ? 1 : 0)
                .padding(.horizontal, 32)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.18)) {
                isVisible = true
            }
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            if let icon = theme.promptIcon {
                icon
                    .font(.system(size: 34))
                    .foregroundStyle(theme.accent)
                    .padding(.top, 4)
            }

            VStack(spacing: 6) {
                Text(copy.promptTitle)
                    .font(theme.titleFont)
                    .multilineTextAlignment(.center)

                Text(copy.promptMessage)
                    .font(theme.messageFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Side by side and the same width, so neither reads as the expected answer.
            // Falls back to a stack when a long translation or a large text size won't fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(spacing: 8) { buttons }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .overlay(alignment: .topTrailing) { closeButton }
        .background(.background, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        // A long press offers a permanent way out. It stays out of the way, but gives
        // anyone who feels nagged a way to stop it themselves.
        .contextMenu {
            Button(
                String(localized: "rater.prompt.optOut", defaultValue: "Don't ask again", bundle: .module),
                systemImage: "bell.slash"
            ) {
                close { onDismiss(true) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var buttons: some View {
        Button { close(onRate) } label: {
            Text(copy.rateLabel)
                .lineLimit(1)
                // Report the label's full width, so a label that doesn't fit makes
                // `ViewThatFits` pick the stacked layout instead of truncating.
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)

        Button { close(onFeedback) } label: {
            Text(copy.feedbackLabel)
                .lineLimit(1)
                // Report the label's full width, so a label that doesn't fit makes
                // `ViewThatFits` pick the stacked layout instead of truncating.
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(theme.accent)
    }

    private var closeButton: some View {
        Button { close { onDismiss(false) } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())
                // The visible circle stays small; only the tap target grows to 44pt.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(4)
        // The "later" copy is no longer drawn as a button, but it is still the right
        // thing for VoiceOver to say about closing the card.
        .accessibilityLabel(copy.laterLabel)
    }

    /// Plays the exit animation before running the callback, so the card doesn't just vanish.
    private func close(_ action: @escaping () -> Void) {
        guard !reduceMotion else { return action() }

        withAnimation(.easeOut(duration: 0.18)) { isVisible = false }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            action()
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()
        RatingPromptView(
            copy: .default, theme: .init(),
            onRate: {}, onFeedback: {}, onDismiss: { _ in }
        )
    }
}
