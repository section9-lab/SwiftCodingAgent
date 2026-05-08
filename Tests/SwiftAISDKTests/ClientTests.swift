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

struct GoogleGenerativeAIEncoderTests {
    private func makeClient(thinkingBudget: Int = 0, includeThoughts: Bool = false) -> GoogleGenerativeAIClient {
        GoogleGenerativeAIClient(
            baseURL: URL(string: "https://example.test/v1beta")!,
            apiKey: "test",
            thinkingBudgetTokens: thinkingBudget,
            includeThoughts: includeThoughts
        )
    }

    @Test
    func collapsesRolesIntoUserAndModel() throws {
        let client = makeClient()
        let contents = client.encodeContents([
            .user("hello"),
            LLMMessage(role: .assistant, content: [.text("hi")])
        ])
        #expect(contents.count == 2)
        #expect(contents[0]["role"] as? String == "user")
        #expect(contents[1]["role"] as? String == "model")
    }

    @Test
    func systemMessagesFoldIntoSystemInstruction() throws {
        let client = makeClient()
        let body = try client.makeRequestBody(from: LLMRequest(
            model: "gemini-2.5-flash",
            messages: [
                .system("be terse"),
                .system("answer in english"),
                .user("hello")
            ]
        ))
        let payload = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let systemInstruction = try #require(payload["systemInstruction"] as? [String: Any])
        let parts = try #require(systemInstruction["parts"] as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts[0]["text"] as? String == "be terse\n\nanswer in english")
        // System messages do NOT appear in `contents`.
        let contents = try #require(payload["contents"] as? [[String: Any]])
        #expect(contents.allSatisfy { ($0["role"] as? String) != "system" })
    }

    @Test
    func toolResultsBecomeFunctionResponseParts() throws {
        let client = makeClient()
        let contents = client.encodeContents([
            LLMMessage(role: .tool, content: [
                .toolResult(LLMToolResult(toolUseID: "call_1", toolName: "read", content: "A")),
                .toolResult(LLMToolResult(toolUseID: "call_2", toolName: "read", content: "boom", isError: true))
            ])
        ])
        #expect(contents.count == 1)
        #expect(contents[0]["role"] as? String == "user")
        let parts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(parts.count == 2)

        let okResponse = try #require(parts[0]["functionResponse"] as? [String: Any])
        #expect(okResponse["id"] as? String == "call_1")
        #expect(okResponse["name"] as? String == "read")
        let okBody = try #require(okResponse["response"] as? [String: Any])
        #expect(okBody["output"] as? String == "A")

        let errResponse = try #require(parts[1]["functionResponse"] as? [String: Any])
        let errBody = try #require(errResponse["response"] as? [String: Any])
        #expect(errBody["error"] as? String == "boom")
    }

    @Test
    func toolUseBecomesFunctionCallPart() throws {
        let client = makeClient()
        let contents = client.encodeContents([
            LLMMessage(role: .assistant, content: [
                .text("looking it up"),
                .toolUse(LLMToolUse(id: "call_1", name: "search", argumentsJSON: #"{"q":"swift"}"#))
            ])
        ])
        #expect(contents.count == 1)
        let parts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["text"] as? String == "looking it up")
        let call = try #require(parts[1]["functionCall"] as? [String: Any])
        #expect(call["id"] as? String == "call_1")
        #expect(call["name"] as? String == "search")
        let args = try #require(call["args"] as? [String: Any])
        #expect(args["q"] as? String == "swift")
    }

    @Test
    func toolSpecBecomesFunctionDeclaration() throws {
        let client = makeClient()
        let body = try client.makeRequestBody(from: LLMRequest(
            model: "gemini-2.5-flash",
            messages: [.user("hi")],
            tools: [
                LLMToolSpec(
                    name: "read",
                    description: "read a file",
                    argumentSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
                )
            ]
        ))
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(payload["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        let decls = try #require(tools[0]["functionDeclarations"] as? [[String: Any]])
        #expect(decls.count == 1)
        #expect(decls[0]["name"] as? String == "read")
        #expect(decls[0]["description"] as? String == "read a file")
        let params = try #require(decls[0]["parametersJsonSchema"] as? [String: Any])
        #expect(params["type"] as? String == "object")
    }

    @Test
    func toolChoiceMappings() throws {
        let client = makeClient()
        let tools = [LLMToolSpec(name: "read", description: "", argumentSchemaJSON: "{}")]

        // .auto omits toolConfig
        let auto = try JSONSerialization.jsonObject(with: try client.makeRequestBody(
            from: LLMRequest(model: "m", messages: [.user("x")], tools: tools, toolChoice: .auto)
        )) as? [String: Any]
        #expect((auto?["toolConfig"]) == nil)

        // .required → ANY
        let required = try JSONSerialization.jsonObject(with: try client.makeRequestBody(
            from: LLMRequest(model: "m", messages: [.user("x")], tools: tools, toolChoice: .required)
        )) as? [String: Any]
        let requiredCfg = try #require(
            (required?["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any]
        )
        #expect(requiredCfg["mode"] as? String == "ANY")
        #expect(requiredCfg["allowedFunctionNames"] == nil)

        // .tool(name) → ANY + allowedFunctionNames
        let specific = try JSONSerialization.jsonObject(with: try client.makeRequestBody(
            from: LLMRequest(model: "m", messages: [.user("x")], tools: tools, toolChoice: .tool(name: "read"))
        )) as? [String: Any]
        let specificCfg = try #require(
            (specific?["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any]
        )
        #expect(specificCfg["mode"] as? String == "ANY")
        #expect(specificCfg["allowedFunctionNames"] as? [String] == ["read"])

        // .none → NONE
        let none = try JSONSerialization.jsonObject(with: try client.makeRequestBody(
            from: LLMRequest(model: "m", messages: [.user("x")], tools: tools, toolChoice: .none)
        )) as? [String: Any]
        let noneCfg = try #require(
            (none?["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any]
        )
        #expect(noneCfg["mode"] as? String == "NONE")
    }

    @Test
    func thinkingConfigEmittedOnlyWhenRequested() throws {
        // Off by default — no thinkingConfig key.
        let off = try JSONSerialization.jsonObject(with: try makeClient().makeRequestBody(
            from: LLMRequest(model: "m", messages: [.user("hi")])
        )) as? [String: Any]
        let offGen = off?["generationConfig"] as? [String: Any]
        #expect((offGen?["thinkingConfig"]) == nil)

        // Budget set: thinkingConfig appears with budget + includeThoughts.
        let on = try JSONSerialization.jsonObject(with: try makeClient(
            thinkingBudget: 1024,
            includeThoughts: true
        ).makeRequestBody(from: LLMRequest(model: "m", messages: [.user("hi")]))) as? [String: Any]
        let onGen = try #require(on?["generationConfig"] as? [String: Any])
        let thinking = try #require(onGen["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingBudget"] as? Int == 1024)
        #expect(thinking["includeThoughts"] as? Bool == true)
    }

    @Test
    func thoughtSignatureRoundTrips() throws {
        // Reasoning with a signature is echoed back as a thought part with
        // its signature; reasoning without a signature is dropped (Gemini
        // rejects signature-less thought parts on input).
        let client = makeClient()
        let contents = client.encodeContents([
            LLMMessage(role: .assistant, content: [
                .reasoning(LLMReasoning(text: "considering", signature: "sig-abc")),
                .reasoning(LLMReasoning(text: "no-sig narration")),
                .text("answer")
            ])
        ])
        let parts = try #require(contents[0]["parts"] as? [[String: Any]])
        // Thought (with sig) + text. The signature-less thought is filtered.
        #expect(parts.count == 2)
        #expect(parts[0]["thought"] as? Bool == true)
        #expect(parts[0]["thoughtSignature"] as? String == "sig-abc")
        #expect(parts[0]["text"] as? String == "considering")
        #expect(parts[1]["text"] as? String == "answer")
        #expect(parts[1]["thought"] == nil)
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
