import Foundation
import Testing
@testable import RaterKit

private let endpoint = URL(string: "https://example.test")!

private func makeClient(_ transport: MockTransport) -> RaterAPIClient {
    RaterAPIClient(endpoint: endpoint, apiKey: "rk_live_test", transport: transport)
}

@Suite("API client")
struct APIClientTests {

    @Test("every request carries the API key")
    func sendsAPIKey() async throws {
        let transport = MockTransport([.init(json: configJSON)])
        _ = try await makeClient(transport).fetchConfig(version: "1.0", locale: "zh-Hans", etag: nil)

        #expect(transport.requests.first?.value(forHTTPHeaderField: "X-Rater-Key") == "rk_live_test")
    }

    @Test("the config request carries version and locale")
    func configQueryParams() async throws {
        let transport = MockTransport([.init(json: configJSON)])
        _ = try await makeClient(transport).fetchConfig(version: "2.1.0", locale: "ja", etag: nil)

        let query = transport.requests.first?.url?.query() ?? ""
        #expect(query.contains("version=2.1.0"))
        #expect(query.contains("locale=ja"))
    }

    @Test("sends If-None-Match when an ETag is known")
    func sendsETag() async throws {
        let transport = MockTransport([.init(status: 304)])
        let result = try await makeClient(transport)
            .fetchConfig(version: "1.0", locale: "en", etag: "\"abc\"")

        #expect(transport.requests.first?.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        if case .notModified = result {} else {
            Issue.record("a 304 should decode as .notModified")
        }
    }

    @Test("decodes the snake_case config response")
    func decodesConfig() async throws {
        let transport = MockTransport([.init(json: configJSON, headers: ["ETag": "\"v1\""])])
        let result = try await makeClient(transport)
            .fetchConfig(version: "1.0", locale: "zh-Hans", etag: nil)

        guard case .fresh(let config, let etag) = result else {
            Issue.record("expected .fresh"); return
        }
        #expect(etag == "\"v1\"")
        #expect(config.enabled)
        #expect(config.appStoreID == "123456789")
        #expect(config.prompt?.positiveLabel == "Yes")
        #expect(config.feedback?.emailRequired == true)
        #expect(config.rules?.minLaunchCount == 3)
    }

    @Test("the submission body is encoded as snake_case")
    func encodesSubmission() async throws {
        let transport = MockTransport([.init(status: 201, json: createdJSON)])
        var device = DiagnosticsPayload()
        device.appVersion = "1.0.0"
        device.deviceModel = "iPhone 16 Pro"

        let response = try await makeClient(transport).createFeedback(
            FeedbackSubmissionBody(
                idempotencyKey: "key-123", message: "something is wrong", category: "bug",
                email: "a@b.com", attachmentCount: 2, device: device, metadata: ["plan": "pro"]
            )
        )

        #expect(response.id == "fb_abc")
        #expect(response.uploadToken == "tok_xyz")
        #expect(response.duplicate == false)

        let body = try #require(transport.requests.first?.httpBody)
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json.contains("\"idempotency_key\":\"key-123\""))
        #expect(json.contains("\"attachment_count\":2"))
        #expect(json.contains("\"device_model\":\"iPhone 16 Pro\""))
    }

    @Test("attachment upload is a PUT carrying the upload token")
    func uploadsAttachment() async throws {
        let transport = MockTransport([.init()])
        try await makeClient(transport).uploadAttachment(
            feedbackID: "fb_abc", index: 1, token: "tok_xyz",
            data: Data([0xFF, 0xD8]), contentType: "image/jpeg"
        )

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/v1/feedback/fb_abc/attachments/1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_xyz")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
    }

    @Test("retries on 5xx")
    func retriesServerErrors() async throws {
        let transport = MockTransport([
            .init(status: 503, json: #"{"error":{"code":"down","message":"under maintenance"}}"#),
            .init(status: 503, json: #"{"error":{"code":"down","message":"under maintenance"}}"#),
            .init(status: 200, json: configJSON),
        ])
        _ = try await makeClient(transport).fetchConfig(version: "1.0", locale: "en", etag: nil)

        #expect(transport.requestCount == 3)
    }

    @Test("does not retry 4xx — the answer will not change")
    func doesNotRetryClientErrors() async throws {
        let transport = MockTransport([
            .init(status: 400, json: #"{"error":{"code":"bad_request","message":"message too short"}}"#)
        ])

        await #expect(throws: RaterError.self) {
            _ = try await makeClient(transport).fetchConfig(version: "1.0", locale: "en", etag: nil)
        }
        #expect(transport.requestCount == 1)
    }

    @Test("surfaces the server's error message")
    func surfacesServerMessage() async throws {
        let transport = MockTransport([
            .init(status: 400, json: #"{"error":{"code":"bad_request","message":"message too short"}}"#)
        ])

        do {
            _ = try await makeClient(transport).fetchConfig(version: "1.0", locale: "en", etag: nil)
            Issue.record("expected a throw")
        } catch let error as RaterError {
            #expect(error == .server(status: 400, code: "bad_request", message: "message too short"))
            #expect(error.localizedDescription == "message too short")
        }
    }

    @Test("throws the last error once retries are exhausted")
    func givesUpEventually() async throws {
        let transport = MockTransport()
        transport.alwaysFails = URLError(.notConnectedToInternet)

        await #expect(throws: RaterError.self) {
            _ = try await makeClient(transport).fetchConfig(version: "1.0", locale: "en", etag: nil)
        }
        // The initial attempt plus three backoff retries
        #expect(transport.requestCount == 4)
    }

    @Test("which errors are worth retrying")
    func retryClassification() {
        #expect(RaterError.network("offline").isRetryable)
        #expect(RaterError.server(status: 500, code: nil, message: nil).isRetryable)
        #expect(RaterError.server(status: 429, code: nil, message: nil).isRetryable)
        #expect(!RaterError.server(status: 400, code: nil, message: nil).isRetryable)
        #expect(!RaterError.server(status: 401, code: nil, message: nil).isRetryable)
        #expect(!RaterError.attachmentEncodingFailed.isRetryable)
    }
}

private let configJSON = """
{
  "enabled": true,
  "variant": "default",
  "app_store_id": "123456789",
  "prompt": {
    "title": "Enjoying it?", "message": "Tell us more",
    "positive_label": "Yes", "negative_label": "Not really", "later_label": "Later"
  },
  "feedback": {
    "title": null, "message": null,
    "categories": [{"id": "bug", "label": "Problem"}],
    "email_required": true
  },
  "rules": { "min_launch_count": 3 }
}
"""

private let createdJSON = """
{
  "id": "fb_abc", "upload_token": "tok_xyz", "expires_at": 1700000900,
  "max_attachment_bytes": 5242880, "duplicate": false
}
"""
