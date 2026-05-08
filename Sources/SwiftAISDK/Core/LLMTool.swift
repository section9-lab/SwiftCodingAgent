import Foundation

/// Definition of a tool exposed to the model.
///
/// The schema is provider-agnostic: a JSON Schema string. Each client adapts
/// it into the provider's wire shape (`function.parameters` for OpenAI,
/// `input_schema` for Anthropic).
public struct LLMToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema describing the tool's argument object. Use `"{}"` for tools
    /// that take no arguments.
    public let argumentSchemaJSON: String

    public init(name: String, description: String, argumentSchemaJSON: String) {
        self.name = name
        self.description = description
        self.argumentSchemaJSON = argumentSchemaJSON
    }
}

/// Per-request hint about which tool the model may pick.
///
/// Mapping:
/// - OpenAI Chat Completions: `tool_choice` accepts `"auto"`, `"none"`,
///   `"required"`, or `{"type":"function","function":{"name":...}}`.
/// - OpenAI Responses: same shape under `tool_choice`.
/// - Anthropic Messages: `tool_choice` accepts `{"type":"auto"}`,
///   `{"type":"any"}` (=== required), `{"type":"tool","name":...}`. There is
///   no native "none"; we omit `tools` instead.
public enum LLMToolChoice: Sendable, Equatable {
    case auto
    case none
    case required
    case tool(name: String)
}
