import Foundation

/// Provider-agnostic LLM client.
///
/// Implementations adapt one wire protocol (OpenAI Chat Completions, OpenAI
/// Responses, Anthropic Messages, ...) to the canonical `LLMRequest` /
/// `LLMResponse` shape.
///
/// `complete` is the non-streaming primitive. `stream` is the streaming one.
/// A default `stream` implementation is provided that calls `complete` and
/// synthesises a single block of events; real adapters override it to emit
/// incremental deltas.
public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

public extension LLMClient {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    continuation.yield(.messageStart(LLMStreamMessageStart(
                        providerResponseID: response.providerResponseID
                    )))
                    for (index, block) in response.message.content.enumerated() {
                        switch block {
                        case .text(let text):
                            continuation.yield(.blockStart(LLMStreamBlockStart(
                                blockIndex: index,
                                kind: .text
                            )))
                            if !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                            continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: index)))

                        case .reasoning(let reasoning):
                            continuation.yield(.blockStart(LLMStreamBlockStart(
                                blockIndex: index,
                                kind: .reasoning
                            )))
                            if !reasoning.text.isEmpty {
                                continuation.yield(.reasoningDelta(LLMReasoningDelta(
                                    blockIndex: index,
                                    delta: reasoning.text
                                )))
                            }
                            continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: index)))

                        case .toolUse(let toolUse):
                            continuation.yield(.blockStart(LLMStreamBlockStart(
                                blockIndex: index,
                                kind: .toolUse(id: toolUse.id, name: toolUse.name)
                            )))
                            if !toolUse.argumentsJSON.isEmpty {
                                continuation.yield(.toolArgumentsDelta(LLMToolArgumentsDelta(
                                    blockIndex: index,
                                    delta: toolUse.argumentsJSON
                                )))
                            }
                            continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: index)))

                        case .refusal(let text):
                            continuation.yield(.blockStart(LLMStreamBlockStart(
                                blockIndex: index,
                                kind: .refusal
                            )))
                            if !text.isEmpty { continuation.yield(.textDelta(text)) }
                            continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: index)))

                        case .image, .toolResult:
                            // Inputs only. Should never appear in a response.
                            break
                        }
                    }
                    continuation.yield(.messageStop(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
