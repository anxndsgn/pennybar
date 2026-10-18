import Foundation

/// Transport seam so providers can be tested against canned responses.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("Not an HTTP response")
        }
        return (data, http)
    }
}

extension HTTPClient {
    /// Sends the request and maps non-2xx statuses to `ProviderError`.
    func checkedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await data(for: request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw ProviderError.unauthorized
        case 403:
            throw ProviderError.forbidden(snippet(data))
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        default:
            throw ProviderError.http(status: response.statusCode, body: snippet(data))
        }
    }

    func decode<T: Decodable>(_ type: T.Type, for request: URLRequest) async throws -> T {
        let data = try await checkedData(for: request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding("\(T.self): \(error.localizedDescription) — \(snippet(data))")
        }
    }
}

func snippet(_ data: Data) -> String {
    String(decoding: data.prefix(300), as: UTF8.self)
}

extension URLRequest {
    static func bearer(_ url: URL, token: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

extension URL {
    func appending(query items: [String: String]) -> URL {
        appending(queryItems: items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
    }
}
