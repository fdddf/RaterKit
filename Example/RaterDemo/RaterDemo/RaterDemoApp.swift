import RaterKit
import SwiftUI

/// Demo app for RaterKit. It points at a local `wrangler dev` server by default.
///
/// Before running, from the `worker/` directory:
/// ```
/// npx wrangler d1 migrations apply rater --local && npx wrangler dev
/// npm run register-app -- --name "Demo App" --id demo-app
/// ```
/// Then paste the API key into the "Server" section inside the app.
@main
struct RaterDemoApp: App {
    init() {
        Rater.configure(DemoSettings.load().makeConfiguration())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Mounts the prompt host — both the pre-prompt and the feedback
                // form are presented through it.
                .raterPrompt()
        }
    }
}

/// The demo's own settings, persisted so the server URL and key survive relaunches.
struct DemoSettings: Equatable {
    var endpoint: String
    var appID: String
    var apiKey: String
    var appStoreID: String

    /// Relaxed rules so the prompt can appear immediately. Real apps should use
    /// `RaterConfiguration.defaultRules` or compose their own.
    var useRelaxedRules: Bool

    static let defaults = DemoSettings(
        endpoint: "http://localhost:8787",
        appID: "demo-app",
        apiKey: "",
        appStoreID: "123456789",
        useRelaxedRules: true
    )

    static func load() -> DemoSettings {
        let store = UserDefaults.standard
        return DemoSettings(
            endpoint: store.string(forKey: "demo.endpoint") ?? defaults.endpoint,
            appID: store.string(forKey: "demo.appID") ?? defaults.appID,
            apiKey: store.string(forKey: "demo.apiKey") ?? defaults.apiKey,
            appStoreID: store.string(forKey: "demo.appStoreID") ?? defaults.appStoreID,
            useRelaxedRules: store.object(forKey: "demo.relaxed") as? Bool
                ?? defaults.useRelaxedRules
        )
    }

    func save() {
        let store = UserDefaults.standard
        store.set(endpoint, forKey: "demo.endpoint")
        store.set(appID, forKey: "demo.appID")
        store.set(apiKey, forKey: "demo.apiKey")
        store.set(appStoreID, forKey: "demo.appStoreID")
        store.set(useRelaxedRules, forKey: "demo.relaxed")
    }

    func makeConfiguration() -> RaterConfiguration {
        RaterConfiguration(
            endpoint: URL(string: endpoint) ?? URL(string: "http://localhost:8787")!,
            appID: appID,
            apiKey: apiKey,
            appStoreID: appStoreID,
            rules: useRelaxedRules ? Self.relaxedRules : RaterConfiguration.defaultRules,
            // A 5 second TTL so copy edited in the admin console shows up right away.
            configCacheTTL: 5,
            isDebugLoggingEnabled: true
        )
    }

    /// Demo rules: exported twice *or* installed for a day, and not shown too often.
    /// This is exactly the "either of these is good enough" shape `anyOf` exists for.
    static var relaxedRules: [any TriggerRule] {
        [
            .notAfterRated,
            .notAfterOptOut,
            .remoteEnabled,
            .anyOf([
                .event("export", atLeast: 2),
                .daysSinceInstall(atLeast: 1),
            ]),
            .maxPromptsPerVersion(3),
        ]
    }
}
