import Foundation

/// One question presented to the user.
public struct AskQuestion: Sendable {
    public let id: String
    public let question: String
    public let options: [String]
    public let multi: Bool
    public let recommended: Int?

    public init(
        id: String,
        question: String,
        options: [String],
        multi: Bool = false,
        recommended: Int? = nil
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.multi = multi
        self.recommended = recommended
    }
}

/// User's response to a single question.
public struct AskAnswer: Sendable {
    public let id: String
    /// Selected option labels. Always at least one element when the user
    /// responded normally; empty if the question was skipped or aborted.
    public let selections: [String]
    /// Free-form text when the user picked the "Other (type your own)" path.
    public let customInput: String?

    public init(id: String, selections: [String], customInput: String? = nil) {
        self.id = id
        self.selections = selections
        self.customInput = customInput
    }
}

/// Closure that drives the interactive UI for a batch of questions.
/// Implementations must answer every question (in order) and return an array
/// the same length as `questions`. Throw `AskError.aborted` to bubble a user
/// cancel back to the model as a tool error.
public typealias AskHandler = @Sendable ([AskQuestion]) async throws -> [AskAnswer]

public enum AskError: LocalizedError {
    case noHandler
    case aborted
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .noHandler:
            return "ask: no AskHandler configured. Pass `askHandler:` to AgentSDK to enable the ask tool."
        case .aborted:
            return "ask: user aborted"
        case .invalidResponse(let msg):
            return "ask: invalid response from handler: \(msg)"
        }
    }
}

/// `ask` tool. Asks the user a clarifying question (or batch of related
/// questions) during execution. The hosting app provides an `AskHandler`
/// closure that drives the actual UI prompt.
public struct AskTool: AgentTool {
    public let name = "ask"
    public let description: String
    public let argumentSchemaJSON = """
    {"type":"object","properties":{"questions":{"type":"array","minItems":1,"items":{"type":"object","properties":{"id":{"type":"string"},"question":{"type":"string"},"options":{"type":"array","minItems":1,"items":{"type":"object","properties":{"label":{"type":"string"}},"required":["label"]}},"multi":{"type":"boolean"},"recommended":{"type":"integer","minimum":0}},"required":["id","question","options"]}}},"required":["questions"]}
    """

    private let handler: AskHandler

    public init(handler: @escaping AskHandler, description: String? = nil) {
        self.handler = handler
        self.description = description ?? Self.defaultDescription
    }

    public static let defaultDescription: String = """
    Ask the user a clarifying question or batch of related questions during execution.

    Use only when multiple approaches exist with materially different tradeoffs the user must weigh.
    Default to action: resolve ambiguity yourself using repo conventions and defaults whenever possible.

    Schema: `questions: [{id, question, options: [{label}], multi?, recommended?}]`.
    Provide 2-5 concise distinct options per question. Set `multi: true` to allow multi-select.
    Use `recommended: <0-indexed>` to mark the default; the UI adds " (Recommended)" automatically.
    Do NOT include an "Other" option — the UI adds "Other (type your own)" automatically.
    """

    private struct OptionItem: Decodable {
        let label: String
    }

    private struct QuestionPayload: Decodable {
        let id: String
        let question: String
        let options: [OptionItem]
        let multi: Bool?
        let recommended: Int?
    }

    private struct Args: Decodable {
        let questions: [QuestionPayload]
    }

    public func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.invalidArguments("Arguments are not UTF-8")
        }
        let args = try JSONDecoder.toolDecoder.decode(Args.self, from: data)

        let questions: [AskQuestion] = args.questions.map { payload in
            AskQuestion(
                id: payload.id,
                question: payload.question,
                options: payload.options.map(\.label),
                multi: payload.multi ?? false,
                recommended: payload.recommended
            )
        }

        let answers = try await handler(questions)

        guard answers.count == questions.count else {
            throw AskError.invalidResponse(
                "expected \(questions.count) answers, got \(answers.count)"
            )
        }

        let questionsByID = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
        var lines: [String] = []
        for answer in answers {
            guard let q = questionsByID[answer.id] else {
                throw AskError.invalidResponse("answer references unknown question id: \(answer.id)")
            }
            lines.append("Q: \(q.question)")
            if let custom = answer.customInput, !custom.isEmpty {
                lines.append("A: (custom) \(custom)")
            } else if answer.selections.isEmpty {
                lines.append("A: (no answer)")
            } else {
                lines.append("A: \(answer.selections.joined(separator: ", "))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
