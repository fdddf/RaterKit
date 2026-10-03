import SwiftUI

/// Everything this device has sent, each one a conversation with you.
///
/// An entry point with no fixed home — the app decides where it goes. Push it from a row
/// inside your own `NavigationStack`:
/// ```swift
/// NavigationLink {
///     RaterConversationsView()
/// } label: {
///     Label("My feedback", systemImage: "bubble.left.and.text.bubble.right")
///         .badge(Rater.shared.unreadCount)
/// }
/// ```
/// or present it on its own with `.raterConversations(isPresented:)`. It needs a
/// navigation stack around it to open a conversation.
public struct RaterConversationsView: View {
    @State private var model = ConversationListModel()
    @State private var showsFeedbackForm = false
    @State private var rater = Rater.shared

    public init() {}

    public var body: some View {
        content
            .navigationTitle(Text("rater.conversations.title", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsFeedbackForm = true
                    } label: {
                        Label {
                            Text("rater.conversations.new", bundle: .module)
                        } icon: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
            .raterFeedbackSheet(isPresented: $showsFeedbackForm)
            .onChange(of: showsFeedbackForm) { _, showing in
                // Whatever was just sent should be in the list when the form goes.
                if !showing { Task { await model.load() } }
            }
            .task { await model.poll() }
            .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if let threads = model.threads {
            if threads.isEmpty {
                emptyState
            } else {
                list(threads)
            }
        } else if let error = model.errorMessage {
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
                    Task { await model.load() }
                } label: {
                    Text("rater.conversations.retry", bundle: .module)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("rater.conversations.emptyTitle", bundle: .module)
            } icon: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
        } description: {
            Text("rater.conversations.emptyMessage", bundle: .module)
        } actions: {
            Button {
                showsFeedbackForm = true
            } label: {
                Text("rater.conversations.send", bundle: .module)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(rater.currentTheme.accent)
        }
    }

    private func list(_ threads: [ThreadSummary]) -> some View {
        List {
            ForEach(threads) { thread in
                NavigationLink {
                    ConversationThreadView(threadID: thread.id, summary: thread)
                } label: {
                    ThreadRow(
                        thread: thread,
                        title: rater.categoryLabel(for: thread.category),
                        accent: rater.currentTheme.accent
                    )
                }
                .onAppear {
                    if thread.id == threads.last?.id {
                        Task { await model.loadMore() }
                    }
                }
            }
            if model.isLoadingMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// One conversation in the list: what it's about, the latest word, and whether there's
/// a reply waiting.
private struct ThreadRow: View {
    let thread: ThreadSummary
    let title: String?
    let accent: Color

    private var isUnread: Bool { thread.unreadCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Group {
                    if let title {
                        Text(title)
                    } else {
                        Text("rater.form.title", bundle: .module)
                    }
                }
                .font(.subheadline.weight(isUnread ? .semibold : .regular))
                .lineLimit(1)

                if thread.isResolved {
                    Label {
                        Text("rater.conversations.resolved", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(thread.lastMessageAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top) {
                Text(thread.preview)
                    .font(.subheadline)
                    .foregroundStyle(isUnread ? .primary : .secondary)
                    .lineLimit(2)

                Spacer(minLength: 8)

                if isUnread {
                    Text(thread.unreadCount, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent))
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Presents `RaterConversationsView` in a sheet of its own.
struct RaterConversationsSheetModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            NavigationStack {
                RaterConversationsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                isPresented = false
                            } label: {
                                Text("rater.form.done", bundle: .module)
                            }
                        }
                    }
            }
        }
    }
}
