import Testing
@testable import SwiftHarnessAgent
import Foundation

struct AnthropicChatModelTests {
    private func makeModel() -> AnthropicChatModel {
        AnthropicChatModel(apiKey: "test", modelName: "claude-test")
    }

    @Test
    func encodesAssistantMessageWithMultipleToolUseBlocks() throws {
        let model = makeModel()
        let messages: [AgentMessage] = [
            .user("hello"),
            AgentMessage(
                role: .assistant,
                text: "I will look at two files.",
                toolCalls: [
                    ToolCall(id: "call_a", name: "read", argumentsJSON: #"{"path":"a.txt"}"#),
                    ToolCall(id: "call_b", name: "read", argumentsJSON: #"{"path":"b.txt"}"#)
                ]
            ),
            AgentMessage(
                role: .tool,
                toolResults: [
                    ToolResult(toolCallID: "call_a", toolName: "read", content: "A"),
                    ToolResult(toolCallID: "call_b", toolName: "read", content: "B")
                ]
            )
        ]

        let encoded = model.encodeMessages(messages)

        #expect(encoded.count == 3)

        // user
        #expect(encoded[0]["role"] as? String == "user")

        // assistant: text + 2 tool_use
        #expect(encoded[1]["role"] as? String == "assistant")
        let assistantBlocks = try #require(encoded[1]["content"] as? [[String: Any]])
        #expect(assistantBlocks.count == 3)
        #expect(assistantBlocks[0]["type"] as? String == "text")
        #expect(assistantBlocks[1]["type"] as? String == "tool_use")
        #expect(assistantBlocks[1]["id"] as? String == "call_a")
        #expect(assistantBlocks[1]["name"] as? String == "read")
        #expect(assistantBlocks[2]["type"] as? String == "tool_use")
        #expect(assistantBlocks[2]["id"] as? String == "call_b")

        // tool results -> single user turn with two tool_result blocks
        #expect(encoded[2]["role"] as? String == "user")
        let toolBlocks = try #require(encoded[2]["content"] as? [[String: Any]])
        #expect(toolBlocks.count == 2)
        #expect(toolBlocks[0]["type"] as? String == "tool_result")
        #expect(toolBlocks[0]["tool_use_id"] as? String == "call_a")
        #expect(toolBlocks[1]["tool_use_id"] as? String == "call_b")
    }

    @Test
    func systemMessagesAreLiftedToTopLevel() throws {
        let model = makeModel()
        let request = ModelRequest(
            messages: [
                .system("you are concise"),
                .system("answer in english"),
                .user("hi")
            ],
            tools: []
        )

        let body = try model.makeRequestBody(from: request)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["system"] as? String == "you are concise\n\nanswer in english")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
    }

    @Test
    func toolUseInputIsParsedJSONNotString() throws {
        let model = makeModel()
        let messages: [AgentMessage] = [
            AgentMessage(
                role: .assistant,
                text: "",
                toolCalls: [
                    ToolCall(id: "x", name: "read", argumentsJSON: #"{"path":"a.txt","limit":10}"#)
                ]
            )
        ]

        let encoded = model.encodeMessages(messages)
        let blocks = try #require(encoded[0]["content"] as? [[String: Any]])
        let toolUse = blocks[0]
        let input = try #require(toolUse["input"] as? [String: Any])
        #expect(input["path"] as? String == "a.txt")
        #expect(input["limit"] as? Int == 10)
    }

    @Test
    func emptyAssistantMessageIsDropped() {
        let model = makeModel()
        let encoded = model.encodeMessages([
            AgentMessage(role: .assistant, text: "", toolCalls: [])
        ])
        #expect(encoded.isEmpty)
    }

    @Test
    func toolResultIsErrorFlagPropagates() throws {
        let model = makeModel()
        let encoded = model.encodeMessages([
            AgentMessage(
                role: .tool,
                toolResults: [
                    ToolResult(toolCallID: "x", toolName: "bash", content: "boom", isError: true)
                ]
            )
        ])
        let blocks = try #require(encoded[0]["content"] as? [[String: Any]])
        #expect(blocks[0]["is_error"] as? Bool == true)
    }
}

struct OpenAIEncoderTests {
    private func makeModel() -> OpenAICompatibleChatModel {
        OpenAICompatibleChatModel(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test",
            modelName: "gpt-test"
        )
    }

    @Test
    func assistantMessageEmitsToolCallsArray() throws {
        let model = makeModel()
        let encoded = model.encodeMessages([
            AgentMessage(
                role: .assistant,
                text: "",
                toolCalls: [
                    ToolCall(id: "1", name: "read", argumentsJSON: #"{"path":"a"}"#),
                    ToolCall(id: "2", name: "read", argumentsJSON: #"{"path":"b"}"#)
                ]
            )
        ])

        #expect(encoded.count == 1)
        let toolCalls = try #require(encoded[0]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 2)
        let function0 = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect(function0["name"] as? String == "read")
        // arguments must be a string per OpenAI spec
        #expect(function0["arguments"] as? String == #"{"path":"a"}"#)
    }

    @Test
    func toolResultsExpandToOneToolMessageEach() throws {
        let model = makeModel()
        let encoded = model.encodeMessages([
            AgentMessage(
                role: .tool,
                toolResults: [
                    ToolResult(toolCallID: "1", toolName: "read", content: "A"),
                    ToolResult(toolCallID: "2", toolName: "read", content: "B")
                ]
            )
        ])

        #expect(encoded.count == 2)
        #expect(encoded[0]["role"] as? String == "tool")
        #expect(encoded[0]["tool_call_id"] as? String == "1")
        #expect(encoded[0]["content"] as? String == "A")
        #expect(encoded[1]["tool_call_id"] as? String == "2")
    }
}
