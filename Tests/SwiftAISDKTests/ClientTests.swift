import Testing
@testable import SwiftAISDK
import Foundation

struct OpenAIChatCompletionsEncoderTests {
    private func makeClient() -> OpenAIChatCompletionsClient {
        OpenAIChatCompletionsClient(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test",
            supportsTools: true
        )
    }

    @Test
    func encodesAssistantMessageWithMultipleToolUses() throws {
        let client = makeClient()
        let messages: [LLMMessage] = [
            .user("hello"),
            LLMMessage(
                role: .assistant,
                content: [
                    .text("I will look at two files."),
                    .toolUse(LLMToolUse(id: "call_a", name: "read", argumentsJSON: #"{"path":"a.txt"}"#)),
                    .toolUse(LLMToolUse(id: "call_b", name: "read", argumentsJSON: #"{"path":"b.txt"}"#))
                ]
            ),
            LLMMessage(
                role: .tool,
                content: [
                    .toolResult(LLMToolResult(toolUseID: "call_a", toolName: "read", content: "A")),
                    .toolResult(LLMToolResult(toolUseID: "call_b", toolName: "read", content: "B"))
                ]
            )
        ]

        let encoded = client.encodeMessages(messages)

        #expect(encoded.count == 4)
        #expect(encoded[0]["role"] as? String == "user")
        #expect(encoded[1]["role"] as? String == "assistant")

        let toolCalls = try #require(encoded[1]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 2)
        #expect(toolCalls[0]["id"] as? String == "call_a")
        #expect(toolCalls[1]["id"] as? String == "call_b")

        // Tool results expand to two separate tool messages.
        #expect(encoded[2]["role"] as? String == "tool")
        #expect(encoded[2]["tool_call_id"] as? String == "call_a")
        #expect(encoded[3]["role"] as? String == "tool")
        #expect(encoded[3]["tool_call_id"] as? String == "call_b")
    }

    @Test
    func systemMessagesStayAsSystemRole() {
        let client = makeClient()
        let encoded = client.encodeMessages([
            .system("you are concise"),
            .user("hi")
        ])
        #expect(encoded.count == 2)
        #expect(encoded[0]["role"] as? String == "system")
        #expect(encoded[1]["role"] as? String == "user")
    }

    @Test
    func reasoningBlocksAreNotEchoed() {
        let client = makeClient()
        let encoded = client.encodeMessages([
            LLMMessage(role: .assistant, content: [
                .reasoning(LLMReasoning(text: "Let me think...")),
                .text("The answer is 42")
            ])
        ])
        #expect(encoded.count == 1)
        #expect(encoded[0]["role"] as? String == "assistant")
        // Only the text is sent back; reasoning is transient.
        #expect(encoded[0]["content"] as? String == "The answer is 42")
    }
}

struct AnthropicMessagesEncoderTests {
    private func makeClient() -> AnthropicMessagesClient {
        AnthropicMessagesClient(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test"
        )
    }

    @Test
    func encodesAssistantMessageWithThinkingAndToolUse() throws {
        let client = makeClient()
        let messages: [LLMMessage] = [
            .user("solve this"),
            LLMMessage(role: .assistant, content: [
                .reasoning(LLMReasoning(text: "Let me think...", signature: "sig123")),
                .text("I will use a tool."),
                .toolUse(LLMToolUse(id: "call_1", name: "read", argumentsJSON: #"{"path":"a"}"#))
            ])
        ]

        let encoded = client.encodeMessages(messages)

        #expect(encoded.count == 2)
        #expect(encoded[1]["role"] as? String == "assistant")
        let blocks = try #require(encoded[1]["content"] as? [[String: Any]])
        #expect(blocks.count == 3)
        #expect(blocks[0]["type"] as? String == "thinking")
        #expect(blocks[0]["thinking"] as? String == "Let me think...")
        #expect(blocks[0]["signature"] as? String == "sig123")
        #expect(blocks[1]["type"] as? String == "text")
        #expect(blocks[2]["type"] as? String == "tool_use")
    }

    @Test
    func toolResultsBecomeSingleUserTurn() throws {
        let client = makeClient()
        let encoded = client.encodeMessages([
            LLMMessage(role: .tool, content: [
                .toolResult(LLMToolResult(toolUseID: "1", toolName: "read", content: "A")),
                .toolResult(LLMToolResult(toolUseID: "2", toolName: "read", content: "B"))
            ])
        ])

        #expect(encoded.count == 1)
        #expect(encoded[0]["role"] as? String == "user")
        let blocks = try #require(encoded[0]["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "tool_result")
        #expect(blocks[0]["tool_use_id"] as? String == "1")
        #expect(blocks[1]["tool_use_id"] as? String == "2")
    }
}

struct OpenAIResponsesEncoderTests {
    private func makeClient() -> OpenAIResponsesClient {
        OpenAIResponsesClient(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test"
        )
    }

    @Test
    func encodesInputAsTypedItems() {
        let client = makeClient()
        let messages: [LLMMessage] = [
            .user("hello"),
            LLMMessage(role: .assistant, content: [
                .reasoning(LLMReasoning(text: "thinking", encryptedContent: "enc123", id: "r1")),
                .text("answer"),
                .toolUse(LLMToolUse(id: "call_1", name: "read", argumentsJSON: #"{"path":"a"}"#))
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(LLMToolResult(toolUseID: "call_1", toolName: "read", content: "content"))
            ])
        ]

        let input = client.encodeInput(messages)

        // User message → 1 item
        // Assistant reasoning → 1 item
        // Assistant text → 1 item
        // Assistant tool_use → 1 item
        // Tool result → 1 item
        #expect(input.count == 5)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[1]["type"] as? String == "reasoning")
        #expect(input[1]["id"] as? String == "r1")
        #expect(input[1]["encrypted_content"] as? String == "enc123")
        #expect(input[2]["type"] as? String == "message")
        #expect(input[3]["type"] as? String == "function_call")
        #expect(input[3]["call_id"] as? String == "call_1")
        #expect(input[4]["type"] as? String == "function_call_output")
        #expect(input[4]["call_id"] as? String == "call_1")
    }
}

struct SSEParserTests {
    @Test
    func splitsEventsOnBlankLines() {
        var parser = SSEParser()
        let events = parser.feed("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n")
        #expect(events == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test
    func handlesPartialChunks() {
        var parser = SSEParser()
        var events = parser.feed("data: {\"hel")
        #expect(events.isEmpty)
        events = parser.feed("lo\":1}\n\n")
        #expect(events == [#"{"hello":1}"#])
    }

    @Test
    func joinsMultipleDataLines() {
        var parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n")
        #expect(events == ["line1\nline2"])
    }

    @Test
    func ignoresCommentsAndOtherFields() {
        var parser = SSEParser()
        let events = parser.feed(": keep-alive\nevent: ping\nid: 1\ndata: ok\n\n")
        #expect(events == ["ok"])
    }

    @Test
    func handlesCRLF() {
        var parser = SSEParser()
        let events = parser.feed("data: hi\r\n\r\n")
        #expect(events == ["hi"])
    }

    @Test
    func passesThroughDoneSentinel() {
        var parser = SSEParser()
        let events = parser.feed("data: [DONE]\n\n")
        #expect(events == ["[DONE]"])
    }
}

struct EchoClientTests {
    @Test
    func echoesLastUserMessage() async throws {
        let client = EchoClient()
        let response = try await client.complete(LLMRequest(
            model: "echo",
            messages: [
                .system("you are helpful"),
                .user("hello world")
            ]
        ))
        #expect(response.message.text == "Echo: hello world")
        #expect(response.stopReason == .endTurn)
    }
}
