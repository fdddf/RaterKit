import Foundation
import Testing
@testable import RaterKit

private let endpoint = URL(string: "https://example.test")!

private func makeLoader(_ transport: MockTransport, ttl: TimeInterval = 3600) -> ConfigLoader {
    ConfigLoader(
        client: RaterAPIClient(endpoint: endpoint, apiKey: "k", transport: transport),
        ttl: ttl,
        fallbackCopy: .default,
        // A distinct cache file per test, so none of them reads another's disk state.
        appID: "test-\(UUID().uuidString)"
    )
}

@Suite("Remote config")
struct ConfigLoaderTests {

    @Test("server copy overrides the bundled fallback")
    func remoteCopyWins() async {
        let loader = makeLoader(MockTransport([.init(json: serverCopyJSON)]))
        let config = await loader.configuration(appVersion: "1.0", locale: "zh-Hans")

        #expect(config.copy.promptTitle == "Working out for you?")
        #expect(config.copy.positiveLabel == "Pretty good")
        #expect(config.isEnabled)
    }

    @Test("no request goes out inside the TTL")
    func honorsTTL() async {
        let transport = MockTransport([.init(json: serverCopyJSON)])
        let loader = makeLoader(transport, ttl: 3600)

        _ = await loader.configuration(appVersion: "1.0", locale: "zh-Hans")
        _ = await loader.configuration(appVersion: "1.0", locale: "zh-Hans")
        _ = await loader.configuration(appVersion: "1.0", locale: "zh-Hans")

        #expect(transport.requestCount == 1)
    }

    @Test("refetches after the TTL, carrying the ETag")
    func refetchesAfterTTL() async throws {
        let transport = MockTransport([
            .init(json: serverCopyJSON, headers: ["ETag": "\"v1\""]),
            .init(status: 304),
        ])
        let loader = makeLoader(transport, ttl: 0)

        _ = await loader.configuration(appVersion: "1.0", locale: "zh-Hans")
        let second = await loader.configuration(appVersion: "1.0", locale: "zh-Hans")

        #expect(transport.requestCount == 2)
        #expect(transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        // After a 304 the previously cached copy should still come back
        #expect(second.copy.promptTitle == "Working out for you?")
    }

    @Test("a version change drops the stale ETag — otherwise the 304 is irrelevant")
    func dropsETagOnVersionChange() async {
        let transport = MockTransport([
            .init(json: serverCopyJSON, headers: ["ETag": "\"v1\""]),
            .init(json: serverCopyJSON, headers: ["ETag": "\"v2\""]),
        ])
        let loader = makeLoader(transport, ttl: 0)

        _ = await loader.configuration(appVersion: "1.0", locale: "zh-Hans")
        _ = await loader.configuration(appVersion: "2.0", locale: "zh-Hans")

        #expect(transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("an unreachable server falls back to bundled copy instead of silencing the prompt")
    func fallsBackWhenOffline() async {
        let transport = MockTransport()
        transport.alwaysFails = URLError(.notConnectedToInternet)

        let config = await makeLoader(transport).configuration(appVersion: "1.0", locale: "en")

        #expect(config.copy.promptTitle == RaterCopy.default.promptTitle)
        #expect(config.isEnabled, "a server outage must not switch prompting off")
    }

    @Test("enabled:false shuts prompting off")
    func respectsKillSwitch() async {
        let json = #"{"enabled":false,"variant":"none","app_store_id":null,"prompt":null,"feedback":null,"rules":null}"#
        let config = await makeLoader(MockTransport([.init(json: json)]))
            .configuration(appVersion: "1.0", locale: "en")

        #expect(!config.isEnabled)
    }

    @Test("server rule overrides are surfaced")
    func surfacesRuleOverrides() async {
        let config = await makeLoader(MockTransport([.init(json: serverCopyJSON)]))
            .configuration(appVersion: "1.0", locale: "zh-Hans")

        #expect(config.rules?.minLaunchCount == 3)
        #expect(config.rules?.cooldownDays == 45)
    }

    @Test("empty server categories keep the bundled defaults")
    func keepsLocalCategoriesWhenServerSendsNone() async {
        let json = """
        {"enabled":true,"variant":"d","app_store_id":null,
         "prompt":null,
         "feedback":{"title":null,"message":null,"categories":[],"email_required":false},
         "rules":null}
        """
        let config = await makeLoader(MockTransport([.init(json: json)]))
            .configuration(appVersion: "1.0", locale: "en")

        #expect(config.copy.categories.count == RaterCopy.default.categories.count)
    }

    @Test("concurrent calls coalesce into one request")
    func coalescesConcurrentCalls() async {
        let transport = MockTransport([.init(json: serverCopyJSON)])
        let loader = makeLoader(transport, ttl: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = await loader.configuration(appVersion: "1.0", locale: "en") }
            }
        }

        #expect(transport.requestCount == 1)
    }

    @Test("invalidate forces a refetch")
    func invalidateForcesRefetch() async {
        let transport = MockTransport([
            .init(json: serverCopyJSON),
            .init(json: serverCopyJSON),
        ])
        let loader = makeLoader(transport, ttl: 3600)

        _ = await loader.configuration(appVersion: "1.0", locale: "en")
        await loader.invalidate()
        _ = await loader.configuration(appVersion: "1.0", locale: "en")

        #expect(transport.requestCount == 2)
    }
}

private let serverCopyJSON = """
{
  "enabled": true,
  "variant": "experiment-b",
  "app_store_id": "999",
  "prompt": {
    "title": "Working out for you?", "message": "Copy edited on the server",
    "positive_label": "Pretty good", "negative_label": "Not really", "later_label": "Later"
  },
  "feedback": {
    "title": "Tell us", "message": null,
    "categories": [{"id": "bug", "label": "Problem"}],
    "email_required": false
  },
  "rules": { "min_launch_count": 3, "cooldown_days": 45 }
}
"""
