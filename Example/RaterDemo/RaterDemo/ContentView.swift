import RaterKit
import SwiftUI

struct ContentView: View {
    @State private var settings = DemoSettings.load()
    @State private var signals: TriggerSignals?
    @State private var decision: TriggerDecision?
    @State private var outcomes: [String] = []
    @State private var pendingCount = 0
    @State private var showsFeedbackSheet = false
    @State private var toast: String?

    private let rater = Rater.shared

    var body: some View {
        NavigationStack {
            Form {
                triggerSection
                stateSection
                directEntriesSection
                outcomesSection
                serverSection
            }
            .navigationTitle("RaterKit Demo")
            .task { await refresh() }
            .task {
                // Subscribe to the event stream so the whole flow is visible live.
                for await outcome in rater.events {
                    outcomes.insert(describe(outcome), at: 0)
                    await refresh()
                }
            }
            .refreshable { await refresh() }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // A standalone entry point that does not rely on `.raterPrompt()` above.
        .raterFeedbackSheet(isPresented: $showsFeedbackSheet)
    }

    // MARK: - Triggering

    private var triggerSection: some View {
        Section {
            Button {
                rater.record(event: "export")
                Task {
                    await refresh()
                    // The full path: record an event, evaluate rules, prompt only if eligible.
                    let shown = await rater.promptIfEligible()
                    if !shown { flash("Rules not satisfied — stayed quiet") }
                }
            } label: {
                Label("Simulate an export, then try to prompt", systemImage: "square.and.arrow.up")
            }

            Button {
                Task { await rater.presentPrompt() }
            } label: {
                Label("Force the pre-prompt (ignore rules)", systemImage: "star.bubble")
            }
        } header: {
            Text("Trigger")
        } footer: {
            Text("The first button is what you would call at a meaningful moment in your own "
                 + "app: `Rater.shared.record(event:)` followed by `promptIfEligible()`.")
        }
    }

    // MARK: - Current state

    @ViewBuilder
    private var stateSection: some View {
        Section {
            if let decision {
                LabeledContent("Eligible right now") {
                    Text(decision.isEligible ? "Yes" : "No")
                        .foregroundStyle(decision.isEligible ? .green : .orange)
                        .fontWeight(.medium)
                }
                if !decision.blockedBy.isEmpty {
                    LabeledContent("Blocked by") {
                        Text(decision.blockedBy.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            if let signals {
                LabeledContent("Days installed", value: "\(signals.daysSinceInstall)")
                LabeledContent("Launches", value: "\(signals.launchCount)")
                LabeledContent("Export events", value: "\(signals.count(of: "export"))")
                LabeledContent("Prompts shown", value: "\(signals.promptCount)")
                LabeledContent("Prompts this version", value: "\(signals.promptCountThisVersion)")
                LabeledContent("Has rated", value: signals.hasRated ? "Yes" : "No")
                LabeledContent("Remote switch", value: signals.remoteEnabled ? "On" : "Off")
                if let rules = signals.remoteRules {
                    LabeledContent("Remote rule overrides") {
                        Text(String(describing: rules)).font(.caption2).lineLimit(3)
                    }
                }
            }
            if pendingCount > 0 {
                LabeledContent("Queued for retry") {
                    Text("\(pendingCount)").foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Current state (TriggerSignals)")
        }
    }

    // MARK: - Direct entry points

    private var directEntriesSection: some View {
        Section {
            Button {
                showsFeedbackSheet = true
            } label: {
                Label("Send feedback (settings-style entry)", systemImage: "envelope")
            }

            Button {
                rater.presentFeedbackForm(category: "bug")
            } label: {
                Label("Report a problem (preselected category)", systemImage: "ladybug")
            }

            Button {
                if !rater.openWriteReviewPage() {
                    flash("No App Store ID configured")
                }
            } label: {
                Label("Open the App Store review page", systemImage: "link")
            }

            Button(role: .destructive) {
                rater.resetLocalState()
                Task {
                    await refresh()
                    outcomes.removeAll()
                    flash("Local state cleared")
                }
            } label: {
                Label("Clear local state", systemImage: "trash")
            }
        } header: {
            Text("Direct entry points")
        }
    }

    // MARK: - Event stream

    @ViewBuilder
    private var outcomesSection: some View {
        if !outcomes.isEmpty {
            Section("Event stream (Rater.shared.events)") {
                ForEach(Array(outcomes.prefix(12).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            LabeledContent("Endpoint") {
                TextField("http://localhost:8787", text: $settings.endpoint)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("App ID") {
                TextField("demo-app", text: $settings.appID)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("API key") {
                TextField("rtr_pub_…", text: $settings.apiKey)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle("Use relaxed demo rules", isOn: $settings.useRelaxedRules)

            Button("Save and reconfigure") {
                settings.save()
                Rater.configure(settings.makeConfiguration())
                Task {
                    await refresh()
                    flash("Reconfigured")
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Edit the copy in the admin console, then hit \"Force the pre-prompt\" — "
                 + "the demo caches config for only 5 seconds, so the change shows up right away.")
        }
    }

    // MARK: - Helpers

    private func refresh() async {
        decision = await rater.evaluate()
        signals = rater.currentSignals
        pendingCount = await rater.pendingFeedbackCount()
    }

    private func flash(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }

    private func describe(_ outcome: RaterOutcome) -> String {
        let time = Date().formatted(date: .omitted, time: .standard)
        return switch outcome {
        case .promptShown: "\(time)  prompt shown"
        case .ratedPositive: "\(time)  positive → StoreKit review"
        case .ratedNegative: "\(time)  negative → feedback form"
        case .promptDismissed: "\(time)  dismissed"
        case .optedOut: "\(time)  opted out"
        case .feedbackOpened: "\(time)  feedback form opened"
        case .feedbackSubmitted(let id): "\(time)  submitted \(id)"
        case .feedbackFailed(let queued): "\(time)  failed\(queued ? " (queued)" : "")"
        case .promptSuppressed(let blocked): "\(time)  suppressed: \(blocked.joined(separator: ","))"
        }
    }
}

#Preview {
    ContentView()
}
