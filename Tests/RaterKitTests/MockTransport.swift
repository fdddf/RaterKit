import Foundation
@testable import RaterKit

/// Scripted transport that replays canned responses and records every request.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, json: String = "{}", headers: [String: String] = [:]) {
            self.status = status
            body = Data(json.utf8)
            self.headers = headers
        }
    }

    private let lock = NSLock()
    private var queue: [Stub] = []
    private var _requests: [URLRequest] = []
    /// When set, every request throws it — for exercising the failure paths.
    var alwaysFails: (any Error)?

    var requests: [URLRequest] { lock.withLock { _requests } }
    var requestCount: Int { lock.withLock { _requests.count } }

    init(_ stubs: [Stub] = []) {
        queue = stubs
    }

    func enqueue(_ stub: Stub) {
        lock.withLock { queue.append(stub) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }

        if let alwaysFails { throw alwaysFails }

        let stub = lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
        guard let stub else {
            return (Data("{}".utf8), Self.response(for: request, status: 200, headers: [:]))
        }
        return (stub.body, Self.response(for: request, status: stub.status, headers: stub.headers))
    }

    private static func response(
        for request: URLRequest, status: Int, headers: [String: String]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
    }

    /// Requests whose path contains the given fragment.
    func requests(matching path: String) -> [URLRequest] {
        requests.filter { $0.url?.path().contains(path) == true }
    }
}
