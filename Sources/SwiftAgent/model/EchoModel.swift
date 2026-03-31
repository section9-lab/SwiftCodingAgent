import Foundation

public struct EchoModel: AgentModel {
    public init() {}

    public func generate(request: ModelRequest) async throws -> ModelResponse {
        let lastUser = request.messages.last(where: { $0.role == .user })?.content ?? ""
        return ModelResponse(content: "Echo: \(lastUser)")
    }
}
