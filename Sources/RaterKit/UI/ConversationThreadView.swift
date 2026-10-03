import SwiftUI

/// One conversation: the feedback that started it, everything said since, and a box to
/// write back. Polls while on screen.
struct ConversationThreadView: View {
    @State private var model: ConversationThreadModel
    @State private var rater = Rater.shared
    @State private var failedMessage: OutgoingMessage?
    @FocusState private var isComposerFocused: Bool

    init(threadID: String, summary: ThreadSummary?) {
        _model = State(initialValue: ConversationThreadModel(threadID: threadID, summary: summary))
    }

    private var accent: Color { rater.currentTheme.accent }

    var body: some View {
        Group {
            if model.detail == nil, let error = model.errorMessage {
                ContentUnavailableView {
                    Label {
                        Text("rater.conversations.loadFailed", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.bubble")
                    }
                } description: {
                    Text(error)
                } actions: {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Text("rater.conversations.retry", bundle: .module)
                    }
                }
            } else {
                transcript
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.run() }
        .confirmationDialog(
            Text("rater.thread.notSent", bundle: .module),
            isPresented: Binding(get: { failedMessage != nil }, set: { if !$0 { failedMessage = nil } }),
            titleVisibility: .visible,
            presenting: failedMessage
        ) { message in
            Button {
                Task { await model.retry(message) }
            } label: {
                Text("rater.conversations.retry", bundle: .module)
            }
            Button(role: .destructive) {
                Task { await model.discard(message) }
            } label: {
                Text("rater.thread.discard", bundle: .module)
            }
        }
    }

    private var title: Text {
        let summary = model.detail?.summary ?? model.summary
        if let label = rater.categoryLabel(for: summary?.category) {
            return Text(label)
        }
        return Text("rater.form.title", bundle: .module)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let detail = model.detail {
                        Bubble(isMine: true, accent: accent) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(detail.message)
                                if detail.attachmentCount > 0 {
                                    Label {
                                        Text(detail.attachmentCount, format: .number)
                                    } icon: {
                                        Image(systemName: "photo.on.rectangle")
                                    }
                                    .font(.caption)
                                    .opacity(0.85)
                                }
                            }
                        } footer: {
                            Text(detail.summary.createdAt, format: .dateTime.month().day().hour().minute())
                        }
                    } else {
                        ProgressView().padding(.top, 40)
                    }

                    ForEach(model.messages) { message in
                        Bubble(isMine: message.isFromUser, accent: accent) {
                            Text(message.body)
                        } footer: {
                            Text(message.createdAt, format: .dateTime.month().day().hour().minute())
                        }
                        .id(message.id)
                    }

                    ForEach(model.outgoing) { message in
                        outgoingBubble(message).id(message.id)
                    }

                    if model.isResolved {
                        Text("rater.thread.resolvedNote", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                    }

                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer }
            .onChange(of: model.messages.count + model.outgoing.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: isComposerFocused) { _, focused in
                guard focused else { return }
                // Wait for the keyboard to settle, then keep the latest message in view.
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
        }
    }

    private static let bottomID = "rater.thread.bottom"

    private func outgoingBubble(_ message: OutgoingMessage) -> some View {
        Bubble(isMine: true, accent: accent, isFaded: true) {
            Text(message.pending.body)
        } footer: {
            switch message.state {
            case .sending:
                Text("rater.thread.sending", bundle: .module)
            case .failed(let queued):
                Button {
                    failedMessage = message
                } label: {
                    Label {
                        if queued {
                            Text("rater.thread.queued", bundle: .module)
                        } else {
                            Text("rater.thread.notSent", bundle: .module)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                String(localized: "rater.thread.placeholder", defaultValue: "Write a reply…", bundle: .module),
                text: $model.draft,
                axis: .vertical
            )
            .lineLimit(1...6)
            .focused($isComposerFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.hierarchical)
            }
            .tint(accent)
            .disabled(!model.canSend)
            .accessibilityLabel(Text("rater.form.send", bundle: .module))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// A chat bubble. The user's own words sit on the trailing side in the accent color;
/// yours sit on the leading side in a neutral fill.
private struct Bubble<Content: View, Footer: View>: View {
    let isMine: Bool
    let accent: Color
    var isFaded = false
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
            content
                .font(.body)
                .foregroundStyle(isMine ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isMine ? accent : Color(.secondarySystemBackground))
                )
                .opacity(isFaded ? 0.6 : 1)

            footer
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(isMine ? .leading : .trailing, 48)
    }
}
