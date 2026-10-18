import Foundation
@testable import PennyBarCore

/// Answers requests from canned bodies keyed by URL path, and records what was asked for.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (status: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: (status: Int, body: String)]) {
        self.routes = routes
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path()
        let route = lock.withLock {
            requests.append(request)
            return routes[path]
        }
        guard let route else { throw URLError(.fileDoesNotExist) }
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!
        return (Data(route.body.utf8), response)
    }

    func query(of index: Int) -> [String: String] {
        let items = URLComponents(url: requests[index].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }
}

let fixedNow = try! Date("2026-10-11T12:00:00Z", strategy: .iso8601)
