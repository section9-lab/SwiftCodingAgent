import Foundation

/// Errors surfaced by SwiftAISDK clients.
///
/// `httpStatus` and `body` are exposed on the `.providerError` case so callers
/// can implement provider-specific retry logic without parsing strings.
public enum LLMError: LocalizedError {
    case invalidResponse(String)
    case providerError(httpStatus: Int, message: String, body: String?)
    case streamingProtocol(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let m):
            return "Invalid response: \(m)"
        case .providerError(let status, let message, let body):
            if let body, !body.isEmpty {
                let trimmed = body.count > 500 ? String(body.prefix(500)) + "…" : body
                return "Provider error (\(status)): \(message) — \(trimmed)"
            }
            return "Provider error (\(status)): \(message)"
        case .streamingProtocol(let m):
            return "Streaming protocol error: \(m)"
        case .encodingFailed(let m):
            return "Failed to encode request: \(m)"
        case .decodingFailed(let m):
            return "Failed to decode response: \(m)"
        case .unsupported(let m):
            return "Unsupported: \(m)"
        }
    }
}
