# RaterKit

[中文](README_CN.md)

Rating prompts and user feedback for iOS, done once and shared across your apps. Swift Package, iOS 17+, pure SwiftUI, no third-party dependencies.

Ask first, at a moment you choose. Happy users go to the system review prompt; unhappy ones get a built-in feedback form instead — message, screenshots, email, and device details — so the complaint reaches you rather than the App Store.

```
                        ┌──────────────┐
   Your app ──trigger─▶ │  Pre-prompt  │ ← copy comes from the server; no app release to change it
                        └──────┬───────┘
                    "I like it" │ "Not quite"
                   ┌────────────┴──────────┐
                   ▼                       ▼
         System review prompt       Built-in feedback form
      (AppStore.requestReview)   email / message / screenshots
                                          │
                                          ▼
                                   rater-collector
```

The server is a separate repository: **[rater-collector](https://github.com/fdddf/rater-collector)** (Cloudflare Worker + D1 + R2, with a built-in admin console). Deploy it first and register an app to get an API key, then come back here.

## Installation

In `Package.swift`, or Xcode → Add Package Dependency:

```swift
.package(url: "https://github.com/fdddf/RaterKit.git", from: "1.0.0")
```

## Usage

```swift
import RaterKit

@main
struct MyApp: App {
    init() {
        Rater.configure(
            .init(
                // wrangler prints this URL when you deploy rater-collector
                endpoint: URL(string: "https://rater-collector.<your-cf-subdomain>.workers.dev")!,
                appID: "my-app",
                apiKey: "rtr_pub_xxx",
                appStoreID: "123456789"
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView().raterPrompt()
        }
    }
}
```

Record the moments that matter, and let the rules decide when to ask:

```swift
Rater.shared.record(event: "export_completed")
await Rater.shared.promptIfEligible()
```

## Four ways in

```swift
await Rater.shared.promptIfEligible()     // asks only if every rule passes (the common case)
Rater.shared.record(event: "export")      // record a significant action
await Rater.shared.presentPrompt()        // force the prompt, bypassing rules (settings screen)
Rater.shared.presentFeedbackForm()        // open the feedback form directly
```

In SwiftUI, attach `.raterPrompt()` to your root view. A settings screen presented as a sheet is *above* that root, so a prompt raised from inside one would be drawn where nobody can see it: use the two standalone entries instead — `.raterRatingPrompt(isPresented:)` for a "Rate this app" row and `.raterFeedbackSheet(isPresented:)` for "Send feedback". Both present themselves and neither depends on `.raterPrompt()`. UIKit hosts use `RaterUIKitPresenter`.

## Trigger rules

This is the main thing you'll customize. **Every** rule must pass before the pre-prompt appears:

```swift
Rater.configure(.init(
    endpoint: ..., appID: ..., apiKey: ...,
    rules: [
        .notAfterRated,                 // never ask someone who already rated
        .notAfterOptOut,                // never ask someone who said no
        .remoteEnabled,                 // the server can switch it off at any time
        .anyOf([                        // either one of these is enough
            .event("export", atLeast: 2),
            .daysSinceInstall(atLeast: 1),
        ]),
        .maxPromptsPerVersion(1),
        .cooldown(days: 60),
        .custom("isPaidUser") { _ in Subscription.shared.isActive },
    ]
))
```

Omit `rules` and you get `RaterConfiguration.defaultRules`: installed at least 3 days, launched at least 5 times, not already prompted on this version, at least 60 days since the last prompt, never again once rated or opted out, and the server can shut it off. That's a reasonable shipping default for most utility apps.

Five of the built-ins — `daysSinceInstall`, `launchCount`, `totalEvents`, `cooldown`, `maxPromptsPerVersion` — **read server-pushed thresholds first**, treating the numbers in your code as defaults. That's how prompt timing gets tuned without shipping an app update.

While tuning, set `isDebugLoggingEnabled: true` or inspect a decision directly. The engine **deliberately doesn't short-circuit**, so `blockedBy` lists every rule that failed rather than just the first:

```swift
let decision = await Rater.shared.evaluate()
print(decision.blockedBy)   // e.g. ["launchCount(atLeast: 5)", "cooldown(days: 60)"]
```

## What else is in the box

- **Remote config** with a two-layer cache (memory + disk), ETag revalidation, and request coalescing. `configCacheTTL` defaults to 6 hours.
- **Offline retry queue** — a failed submission is persisted and replayed once `NWPathMonitor` sees the network return. The idempotency key means a replay can never produce a duplicate server-side; it gives up after 5 attempts.
- **Screenshots** downsampled and JPEG-compressed (long edge 1600px, quality 0.7 by default).
- **Diagnostics** collected and shown to the user in the form, so they can see exactly what will be sent.
- **Telemetry** batched and free of user identifiers.
- **String Catalog** — 11 languages (en, de, es, fr, it, ja, ko, pt, ru, zh-Hans, zh-Hant), with English as the source language. This covers the form's own chrome; the pre-prompt copy and category labels come from remote config, so translate those in the admin console.

The three privacy-relevant behaviors each have their own switch: `collectsDiagnostics`, `isTelemetryEnabled`, `isOfflineRetryEnabled`.

## Example app

`Example/RaterDemo/` is a runnable SwiftUI demo that consumes this package by relative path. Its settings screen takes an API key and base URL at runtime, and `configCacheTTL` is set to 5 seconds so a copy change made in the admin console shows up almost immediately.

```bash
cd Example/RaterDemo && xcodegen generate && open RaterDemo.xcodeproj
```

You'll want the server running alongside it (`npx wrangler dev` in the rater-collector repo).

## Tests

```bash
xcodebuild -scheme RaterKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The package is iOS-only, so `swift test` can't run it on the macOS host — it has to go through a simulator.

## ⚠️ Contract with the server

The fallback copy in `RaterCopy.default` (`Sources/RaterKit/Configuration/RaterConfiguration.swift`) must stay **word-for-word identical** to `FALLBACK` in the rater-collector repo's `src/routes/config.ts`. One is what the client shows when it's offline; the other is what the server sends when no copy is configured. The same user can hit both across two launches, and any difference reads as a bug.

Change one side, change the other. It's the one invariant that splitting into two repositories left for a human to watch.

## License

MIT
