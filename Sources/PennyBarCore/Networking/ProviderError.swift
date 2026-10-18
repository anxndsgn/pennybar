import Foundation

public enum ProviderError: Error, Equatable, LocalizedError {
    case unauthorized
    case forbidden(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, body: String)
    case decoding(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "The token was rejected. Check that it is valid and not expired."
        case .forbidden(let detail):
            "The token lacks permission for billing data. \(detail)"
        case .rateLimited(let retryAfter):
            if let retryAfter { "Rate limited. Retry in \(Int(retryAfter))s." } else { "Rate limited. Try again later." }
        case .http(let status, let body):
            "HTTP \(status): \(body)"
        case .decoding(let detail):
            "Unexpected response format: \(detail)"
        case .invalidResponse(let detail):
            detail
        }
    }
}
