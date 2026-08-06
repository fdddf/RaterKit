import Foundation
import os

/// Client for the Worker's endpoints. Every network request goes through here.
public actor RaterAPIClient {
    /// Outcome of a conditional config request.
    enum ConfigResult: Sendable {
        case fresh(RemoteConfigResponse, etag: String?)
        case notModified
    }

    private let endpoint: URL
    private let apiKey: String
    private let transport: any HTTPTransport
    private let logger: Logger

    /// Backoff delays for retryable failures. Three is plenty — beyond that the user
    /// has moved on anyway, and the offline queue picks up the rest.
    private let backoff: [Duration] = [.milliseconds(400), .milliseconds(1200), .seconds(3)]

    public init(endpoint: URL, apiKey: String, transport: any HTTPTransport = URLSession.shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
        logger = Logger(subsystem: "com.raterkit", category: "api")
    }

    // MARK: - Endpoints

    func fetchConfig(version: String, locale: String, etag: String?) async throws -> ConfigResult {
        var components = URLComponents(url: endpoint.appending(path: "v1/config"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "locale", value: locale),
        ]
        guard let url = components?.url else { throw RaterError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Rater-Key")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await perform(request)
        if response.statusCode == 304 { return .notModified }

        let config = try decode(RemoteConfigResponse.self, from: data)
        return .fresh(config, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    func createFeedback(_ body: FeedbackSubmissionBody) async throws -> FeedbackSubmissionResponse {
        var request = URLRequest(url: endpoint.appending(path: "v1/feedback"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Rater-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await perform(request)
        return try decode(FeedbackSubmissionResponse.self, from: data)
    }

    func uploadAttachment(
        feedbackID: String,
        index: Int,
        token: String,
        data: Data,
        contentType: String
    ) async throws {
        var request = URLRequest(
            url: endpoint.appending(path: "v1/feedback/\(feedbackID)/attachments/\(index)")
        )
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        _ = try await perform(request)
    }

    func completeFeedback(id: String) async throws {
        var request = URLRequest(url: endpoint.appending(path: "v1/feedback/\(id)/complete"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Rater-Key")

        _ = try await perform(request)
    }

    func sendTelemetry(_ body: TelemetryBody) async throws {
        var request = URLRequest(url: endpoint.appending(path: "v1/telemetry"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Rater-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        _ = try await perform(request)
    }

    // MARK: - Transport

    /// Sends a request, backing off on retryable failures. 4xx throws immediately —
    /// retrying won't change the answer.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: RaterError = .invalidResponse

        for attempt in 0...backoff.count {
            do {
                let (data, response) = try await transport.send(request)
                guard (200..<300).contains(response.statusCode) || response.statusCode == 304 else {
                    throw serverError(status: response.statusCode, data: data)
                }
                return (data, response)
            } catch let error as RaterError {
                lastError = error
                guard error.isRetryable, attempt < backoff.count else { throw error }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = .network(error.localizedDescription)
                guard attempt < backoff.count else { throw lastError }
            }

            logger.debug("retry \(attempt + 1) for \(request.url?.path ?? "?")")
            try await Task.sleep(for: backoff[attempt])
        }

        throw lastError
    }

    private func serverError(status: Int, data: Data) -> RaterError {
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        return .server(status: status, code: body?.error.code, message: body?.error.message)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("failed to decode \(String(describing: type)): \(error.localizedDescription)")
            throw RaterError.invalidResponse
        }
    }
}
