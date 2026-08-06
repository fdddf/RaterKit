import Foundation

/// Minimal seam over URLSession so the API client can run offline in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RaterError.invalidResponse
        }
        return (data, http)
    }
}

public enum RaterError: Error, Sendable, Equatable {
    /// RaterKit was used before `configure(_:)` was called.
    case notConfigured
    case invalidResponse
    /// The server returned 4xx/5xx.
    case server(status: Int, code: String?, message: String?)
    /// A transport-level failure (offline, timeout) — worth retrying.
    case network(String)
    /// A screenshot could not be encoded.
    case attachmentEncodingFailed

    /// Whether trying again later could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .network: true
        case .server(let status, _, _): status >= 500 || status == 429
        case .notConfigured, .invalidResponse, .attachmentEncodingFailed: false
        }
    }

    public var localizedDescription: String {
        switch self {
        case .notConfigured:
            "RaterKit is not configured — call Rater.configure(_:) first."
        case .invalidResponse:
            String(localized: "rater.error.invalidResponse",
                   defaultValue: "The server sent something we couldn't read.", bundle: .module)
        case .server(_, _, let message):
            message ?? String(localized: "rater.error.server",
                              defaultValue: "The server had a problem. Please try again later.",
                              bundle: .module)
        case .network:
            String(localized: "rater.error.network",
                   defaultValue: "No network connection. Check your connection and try again.",
                   bundle: .module)
        case .attachmentEncodingFailed:
            String(localized: "rater.error.attachment",
                   defaultValue: "That screenshot couldn't be processed. Try another one.",
                   bundle: .module)
        }
    }
}
