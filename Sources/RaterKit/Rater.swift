import Foundation
import Network
import SwiftUI
import os

/// RaterKit's main entry point.
///
/// ```swift
/// Rater.configure(.init(endpoint: …, appID: "my-app", apiKey: "rtr_pub_…"))
/// ContentView().raterPrompt()          // mount the presentation host
/// Rater.shared.record(event: "export") // record meaningful moments
/// ```
@MainActor
@Observable
public final class Rater {
    public static let shared = Rater()

    /// What should be on screen. The `.raterPrompt()` modifier observes this.
    public internal(set) var presentation: RaterPresentation?

    /// Stream of everything that happens, to feed your own analytics.
    public var events: AsyncStream<RaterOutcome> { eventStream }

    @ObservationIgnored private var configuration: RaterConfiguration?
    @ObservationIgnored private var store: any RaterStore = InMemoryStore()
    @ObservationIgnored private var client: RaterAPIClient?
    @ObservationIgnored private var configLoader: ConfigLoader?
    @ObservationIgnored private var submitter: FeedbackSubmitter?
    @ObservationIgnored private var telemetry: TelemetryReporter?
    @ObservationIgnored private var outbox: Outbox?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    /// The most recently fetched remote config, reused by the form and telemetry.
    @ObservationIgnored private var remoteConfig: RemotePromptConfig?
    @ObservationIgnored private var extraMetadata: [String: String] = [:]

    @ObservationIgnored private var eventStream: AsyncStream<RaterOutcome> = .init { _ in }
    @ObservationIgnored private var eventContinuation: AsyncStream<RaterOutcome>.Continuation?

    @ObservationIgnored private let logger = Logger(subsystem: "com.raterkit", category: "rater")

    /// Review requester injected by the view layer (SwiftUI's `requestReview`), falling
    /// back to calling StoreKit directly when there isn't one.
    @ObservationIgnored var reviewRequester: (any ReviewRequesting)?

    init() {
        let (stream, continuation) = AsyncStream<RaterOutcome>.makeStream()
        eventStream = stream
        eventContinuation = continuation
    }

    // MARK: - Configuration

    /// Configures RaterKit. Call it early, normally from `App.init()`.
    ///
    /// It also records a launch, warms up the remote config, and flushes the offline queue.
    public static func configure(_ configuration: RaterConfiguration) {
        shared.apply(configuration)
    }

    func apply(_ configuration: RaterConfiguration, transport: (any HTTPTransport)? = nil) {
        self.configuration = configuration
        store = UserDefaultsStore(suiteName: configuration.userDefaultsSuiteName)

        let client = RaterAPIClient(
            endpoint: configuration.endpoint,
            apiKey: configuration.apiKey,
            transport: transport ?? URLSession.shared
        )
        self.client = client

        let outbox = Outbox(appID: configuration.appID)
        self.outbox = outbox
        configLoader = ConfigLoader(
            client: client, ttl: configuration.configCacheTTL,
            fallbackCopy: configuration.fallbackCopy, appID: configuration.appID
        )
        submitter = FeedbackSubmitter(
            client: client, outbox: outbox,
            isOfflineRetryEnabled: configuration.isOfflineRetryEnabled
        )
        telemetry = TelemetryReporter(client: client, isEnabled: configuration.isTelemetryEnabled)

        recordLaunch()

        if configuration.isOfflineRetryEnabled {
            startNetworkMonitor()
        }

        Task { [weak self] in
            // Warm the copy now so nothing has to be fetched at the moment we prompt.
            await self?.refreshRemoteConfig()
            await self?.submitter?.flushOutbox()
        }
    }

    /// Key/values attached to every subsequent feedback (plan, experiment bucket, and
    /// the like). Don't put anything that identifies a person in here.
    public func setMetadata(_ metadata: [String: String]) {
        extraMetadata = metadata
    }

    // MARK: - Recording

    /// Records a launch. `configure(_:)` already does this once; call it manually only
    /// if you need to count something else as a session.
    public func recordLaunch() {
        let version = DeviceInfo.current.appVersion
        store.mutate { state in
            state.launchCount += 1
            state.launchCountByVersion[version, default: 0] += 1
        }
    }

    /// Records a meaningful action — the most direct signal that someone is actually
    /// getting value out of the app.
    ///
    /// ```swift
    /// Rater.shared.record(event: "photo_exported")
    /// ```
    /// Pairs with the `.event("photo_exported", atLeast: 3)` rule.
    public func record(event: String, count: Int = 1) {
        store.mutate { $0.eventCounts[event, default: 0] += count }
    }

    // MARK: - Prompting

    /// Shows the pre-prompt only if every rule passes; otherwise returns false quietly.
    ///
    /// This is the entry point you'll use most: call it at moments that feel right, and
    /// let the rules decide whether it's actually worth interrupting anyone.
    @discardableResult
    public func promptIfEligible() async -> Bool {
        let decision = await evaluate()

        if configuration?.isDebugLoggingEnabled == true {
            logger.notice("trigger decision: \(decision.description, privacy: .public)")
        }

        guard decision.isEligible else {
            emit(.promptSuppressed(blockedBy: decision.blockedBy))
            return false
        }

        await presentPrompt()
        return true
    }

    /// Shows the pre-prompt regardless of the rules. Suited to a deliberate entry point
    /// such as Settings → Rate this app.
    public func presentPrompt() async {
        let config = await refreshRemoteConfig()
        let version = DeviceInfo.current.appVersion

        store.mutate { state in
            state.lastPromptDate = Date()
            state.promptCount += 1
            state.promptCountByVersion[version, default: 0] += 1
        }

        presentation = .prompt(config.copy)
        emit(.promptShown)
    }

    /// Opens the feedback form directly, skipping the pre-prompt. Suited to
    /// Settings → Send feedback.
    public func presentFeedbackForm(category: String? = nil) {
        Task {
            presentation = .feedback(await makeFeedbackContext(category: category))
        }
    }

    /// Fetches fresh config and assembles the context the form needs.
    func makeFeedbackContext(category: String?) async -> FeedbackContext {
        let config = await refreshRemoteConfig()
        emit(.feedbackOpened)
        return FeedbackContext(
            copy: config.copy,
            emailRequired: config.emailRequired || (configuration?.requiresEmail ?? false),
            presetCategory: category,
            prefilledEmail: store.load().lastEmail
        )
    }

    /// Evaluates the rules without prompting. Useful while tuning timing — it's what the
    /// demo app uses to show its current state.
    public func evaluate(at date: Date = Date()) async -> TriggerDecision {
        guard let configuration else {
            return TriggerDecision(isEligible: false, blockedBy: ["notConfigured"],
                                   signals: makeSignals(at: date, remote: nil))
        }
        let config = await refreshRemoteConfig()
        return TriggerEngine(rules: configuration.rules)
            .evaluate(makeSignals(at: date, remote: config))
    }

    /// Clears all local state (launch counts, event counts, prompt history). For debugging.
    public func resetLocalState() {
        store.clear()
        Task {
            await configLoader?.invalidate()
            await outbox?.clear()
        }
    }

    /// The current rule input snapshot, which the demo app renders.
    public var currentSignals: TriggerSignals {
        makeSignals(at: Date(), remote: remoteConfig)
    }

    /// How many submissions are still waiting to be sent.
    public func pendingFeedbackCount() async -> Int {
        await outbox?.count ?? 0
    }

    // MARK: - Prompt callbacks (invoked by the UI layer)

    func handlePositive() {
        store.mutate { $0.hasRated = true }
        presentation = nil
        emit(.ratedPositive)

        Task {
            let requester = reviewRequester ?? StoreKitReviewRequester()
            await requester.requestReview()
        }
    }

    func handleNegative() {
        presentation = nil
        emit(.ratedNegative)
        presentFeedbackForm()
    }

    func handleDismiss(optOut: Bool) {
        store.mutate { state in
            state.lastPromptOutcome = optOut ? "optOut" : "dismissed"
            if optOut { state.hasOptedOut = true }
        }
        presentation = nil
        emit(optOut ? .optedOut : .promptDismissed)
    }

    func dismissFeedback() {
        presentation = nil
    }

    /// Submits a feedback. The UI waits on this before dismissing the form.
    @discardableResult
    func submit(_ draft: FeedbackDraft) async throws -> String {
        guard let submitter, let configuration else { throw RaterError.notConfigured }

        var draft = draft
        draft.metadata.merge(extraMetadata) { current, _ in current }

        // Remember the email so it doesn't have to be typed again.
        if let email = draft.email?.trimmingCharacters(in: .whitespaces), !email.isEmpty {
            store.mutate { $0.lastEmail = email }
        }

        let diagnostics = DiagnosticsPayload(
            state: store.load(), enabled: configuration.collectsDiagnostics
        )

        do {
            let id = try await submitter.submit(draft, device: diagnostics)
            emit(.feedbackSubmitted(id: id))
            return id
        } catch {
            let queued = configuration.isOfflineRetryEnabled
                && ((error as? RaterError)?.isRetryable ?? true)
            emit(.feedbackFailed(queued: queued))
            throw error
        }
    }

    /// The App Store id in effect: server-provided first, then the local configuration.
    var resolvedAppStoreID: String? {
        remoteConfig?.appStoreID ?? configuration?.appStoreID
    }

    var currentConfiguration: RaterConfiguration? { configuration }
    var currentTheme: RaterTheme { configuration?.theme ?? RaterTheme() }
    var maxAttachments: Int { configuration?.maxAttachments ?? 3 }
    var attachmentMaxDimension: CGFloat { configuration?.attachmentMaxDimension ?? 1600 }
    var attachmentQuality: CGFloat { configuration?.attachmentCompressionQuality ?? 0.7 }
    var collectsDiagnostics: Bool { configuration?.collectsDiagnostics ?? true }

    /// The diagnostics shown to the user inside the feedback form.
    var diagnosticsPreview: DiagnosticsPayload {
        DiagnosticsPayload(state: store.load(), enabled: collectsDiagnostics)
    }

    // MARK: - Private

    @discardableResult
    private func refreshRemoteConfig() async -> RemotePromptConfig {
        guard let configLoader else {
            return RemotePromptConfig(
                isEnabled: true, variant: "unconfigured", appStoreID: nil,
                copy: configuration?.fallbackCopy ?? .default, emailRequired: false, rules: nil
            )
        }
        let config = await configLoader.configuration(
            appVersion: DeviceInfo.current.appVersion,
            locale: DeviceInfo.current.locale
        )
        remoteConfig = config
        return config
    }

    private func makeSignals(at date: Date, remote: RemotePromptConfig?) -> TriggerSignals {
        let state = store.load()
        let version = DeviceInfo.current.appVersion
        return TriggerSignals(
            now: date,
            installDate: state.installDate,
            launchCount: state.launchCount,
            launchCountThisVersion: state.launchCountByVersion[version] ?? 0,
            eventCounts: state.eventCounts,
            appVersion: version,
            lastPromptDate: state.lastPromptDate,
            promptCount: state.promptCount,
            promptCountThisVersion: state.promptCountByVersion[version] ?? 0,
            hasRated: state.hasRated,
            hasOptedOut: state.hasOptedOut,
            remoteEnabled: remote?.isEnabled ?? true,
            remoteRules: remote?.rules
        )
    }

    private func emit(_ outcome: RaterOutcome) {
        eventContinuation?.yield(outcome)
        let device = DeviceInfo.current
        let variant = remoteConfig?.variant ?? "default"
        Task { [telemetry] in
            await telemetry?.record(outcome, appVersion: device.appVersion,
                                    variant: variant, locale: device.locale)
        }
    }

    /// Replays the backlog automatically when connectivity returns.
    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                await self?.submitter?.flushOutbox()
                await self?.telemetry?.flush()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.raterkit.network"))
        pathMonitor = monitor
    }
}

/// What is currently being presented.
public enum RaterPresentation: Identifiable, Sendable {
    case prompt(RaterCopy)
    case feedback(FeedbackContext)

    public var id: String {
        switch self {
        case .prompt: "prompt"
        case .feedback: "feedback"
        }
    }
}

/// Context for opening the feedback form.
public struct FeedbackContext: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let copy: RaterCopy
    public let emailRequired: Bool
    public let presetCategory: String?
    public let prefilledEmail: String?

    public static func == (lhs: FeedbackContext, rhs: FeedbackContext) -> Bool {
        lhs.id == rhs.id
    }
}
