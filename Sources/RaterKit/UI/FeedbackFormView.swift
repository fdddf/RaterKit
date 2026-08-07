import SwiftUI

/// The feedback form. Shown after the negative button on the pre-prompt, or from a
/// deliberate entry point such as a settings row.
struct FeedbackFormView: View {
    let context: FeedbackContext
    let theme: RaterTheme
    let onSubmit: (FeedbackDraft) async throws -> String
    let onDismiss: () -> Void

    @State private var draft = FeedbackDraft()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSucceed = false
    @FocusState private var isMessageFocused: Bool

    private let rater = Rater.shared

    var body: some View {
        NavigationStack {
            Group {
                if didSucceed {
                    successView
                } else {
                    form
                }
            }
            .navigationTitle(context.copy.feedbackTitle
                ?? String(localized: "rater.form.title", defaultValue: "Feedback", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "rater.form.cancel", defaultValue: "Cancel", bundle: .module)) {
                        onDismiss()
                    }
                    .disabled(isSubmitting)
                }
                if !didSucceed {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Button(String(localized: "rater.form.send", defaultValue: "Send", bundle: .module)) {
                                Task { await submit() }
                            }
                            .disabled(!draft.canSubmit(emailRequired: context.emailRequired))
                            .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        .task {
            draft.category = context.presetCategory ?? context.copy.categories.first?.id
            draft.email = context.prefilledEmail
            // Focus the message field so there's one less tap before typing.
            try? await Task.sleep(for: .milliseconds(350))
            isMessageFocused = true
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    // MARK: - Form

    private var form: some View {
        Form {
            if let intro = context.copy.feedbackMessage, !intro.isEmpty {
                Section {
                    Text(intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if context.copy.categories.count > 1 {
                Section {
                    Picker(selection: $draft.category) {
                        ForEach(context.copy.categories) { category in
                            Text(category.label).tag(Optional(category.id))
                        }
                    } label: {
                        Text("rater.form.category", bundle: .module)
                    }
                    .pickerStyle(.menu)
                }
            }

            Section {
                TextEditor(text: $draft.message)
                    .frame(minHeight: 130)
                    .focused($isMessageFocused)
                    .overlay(alignment: .topLeading) {
                        if draft.message.isEmpty {
                            Text("rater.form.messagePlaceholder", bundle: .module)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("rater.form.message", bundle: .module)
            } footer: {
                if !draft.message.isEmpty, !draft.isMessageValid {
                    Text("rater.form.messageTooShort", bundle: .module)
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField(
                    String(localized: "rater.form.emailPlaceholder", defaultValue: "you@example.com", bundle: .module),
                    text: Binding(get: { draft.email ?? "" }, set: { draft.email = $0 })
                )
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
                HStack {
                    Text("rater.form.email", bundle: .module)
                    if !context.emailRequired {
                        Text("rater.form.optional", bundle: .module)
                            .foregroundStyle(.tertiary)
                    }
                }
            } footer: {
                if draft.isEmailValid {
                    Text("rater.form.emailHint", bundle: .module)
                } else {
                    Text("rater.form.emailInvalid", bundle: .module).foregroundStyle(.red)
                }
            }

            Section {
                AttachmentPicker(
                    attachments: $draft.attachments,
                    maxCount: rater.maxAttachments,
                    maxDimension: rater.attachmentMaxDimension,
                    quality: rater.attachmentQuality
                )
            }

            diagnosticsSection

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }
        }
    }

    /// Lists the diagnostics that will be uploaded, verbatim.
    ///
    /// This section is deliberate: the user can see exactly what they're sending, and
    /// it's something you can point an App Review reviewer at.
    @ViewBuilder
    private var diagnosticsSection: some View {
        let diagnostics = rater.diagnosticsPreview
        if !diagnostics.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(diagnostics.displayItems, id: \.label) { item in
                        LabeledContent(item.label, value: item.value)
                            .font(.caption)
                    }
                } label: {
                    Label {
                        Text("rater.form.diagnostics", bundle: .module)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.subheadline)
                }
            } footer: {
                Text("rater.form.diagnosticsFooter", bundle: .module)
            }
        }
    }

    private var successView: some View {
        ContentUnavailableView {
            Label {
                Text("rater.form.thanksTitle", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
            }
        } description: {
            Text("rater.form.thanksMessage", bundle: .module)
        } actions: {
            Button {
                onDismiss()
            } label: {
                // Short labels ("Done", "完成") leave the default pill too tight,
                // so the button gets its width from padding rather than the text.
                Text("rater.form.done", bundle: .module)
                    .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.accent)
        }
    }

    // MARK: - Submission

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        isMessageFocused = false
        defer { isSubmitting = false }

        do {
            _ = try await onSubmit(draft)
            withAnimation { didSucceed = true }
            // Let the confirmation land before dismissing.
            try? await Task.sleep(for: .seconds(1.6))
            onDismiss()
        } catch let error as RaterError {
            // Queued counts as sent: the feedback isn't lost, so there's nothing
            // useful the user could do with an error here.
            if error.isRetryable, rater.currentConfiguration?.isOfflineRetryEnabled == true {
                withAnimation { didSucceed = true }
                try? await Task.sleep(for: .seconds(1.6))
                onDismiss()
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
