import Foundation

public protocol AgentSkill: Sendable {
    var name: String { get }
    var systemPrompt: String { get }
    var tools: [any AgentTool] { get }
}

public struct BasicSkill: AgentSkill {
    public let name: String
    public let systemPrompt: String
    public let tools: [any AgentTool]

    public init(name: String, systemPrompt: String, tools: [any AgentTool] = []) {
        self.name = name
        self.systemPrompt = systemPrompt
        self.tools = tools
    }
}
