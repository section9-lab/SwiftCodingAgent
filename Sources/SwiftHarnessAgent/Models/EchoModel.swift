import Foundation

public struct EchoModel: AgentModel {
    public init() {}

    public func generate(request: ModelRequest) async throws -> ModelResponse {
        let lastUser = request.messages.last(where: { $0.role == .user })?.text ?? ""
        return ModelResponse(content: "Echo: \(lastUser)")
    }
}
