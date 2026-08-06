import SwiftUI

/// The pre-prompt.
///
/// Drawn as an overlay rather than a system `alert` for two reasons: the copy has to
/// follow server config and the host's theme, and tapping the negative button needs to
/// flow straight into the feedback form — an alert-to-sheet handoff flickers.
struct RatingPromptView: View {
    let copy: RaterCopy
    let theme: RaterTheme
    let onPositive: () -> Void
    let onNegative: () -> Void
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

            VStack(spacing: 8) {
                Button { close(onPositive) } label: {
                    Text(copy.positiveLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)

                Button { close(onNegative) } label: {
                    Text(copy.negativeLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)

                Button(copy.laterLabel) { close { onDismiss(false) } }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: 340)
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
            onPositive: {}, onNegative: {}, onDismiss: { _ in }
        )
    }
}
