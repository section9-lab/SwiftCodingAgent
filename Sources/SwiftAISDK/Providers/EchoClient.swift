import Foundation

/// Local stub client. Returns `"Echo: <last user text>"` and never calls the
/// network. Useful for tests, demos, and bootstrapping a project before any
/// API keys are wired up.
public struct EchoClient: LLMClient {
    public init() {}

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let lastUser = request.messages
            .last(where: { $0.role == .user })?
            .text ?? ""
        let message = LLMMessage(
            role: .assistant,
            content: [.text("Echo: \(lastUser)")]
        )
        return LLMResponse(
            message: message,
            stopReason: .endTurn,
            usage: nil,
            providerResponseID: nil
        )
    }
}
