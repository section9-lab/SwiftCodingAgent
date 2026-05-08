import Foundation

/// Parses Server-Sent Events from a streaming HTTP body.
///
/// All three of OpenAI Chat Completions, OpenAI Responses, and Anthropic
/// Messages stream over SSE: each event is a set of `field: value` lines
/// terminated by a blank line. We only care about the `data:` field; multiple
/// `data:` lines in one event are joined with `\n`.
///
/// The OpenAI Responses stream additionally puts the typed event name in an
/// `event:` line — we keep that behaviour out of this parser (callers parse
/// the JSON `type` field themselves), so the parser stays a single concern:
/// raw SSE framing.
///
/// We work at the UTF-8 byte level for line splitting because Swift treats
/// `\r\n` as a single extended grapheme cluster — `String.range(of: "\n")`
/// won't find the LF inside a CRLF, which would silently break parsing.
struct SSEParser {
    private var buffer: [UInt8] = []
    private var dataLines: [String] = []

    private static let lf: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D

    /// Feed raw text and return any complete data payloads now available.
    /// Each element is a JSON string (or `[DONE]` for OpenAI Chat Completions).
    mutating func feed(_ chunk: String) -> [String] {
        buffer.append(contentsOf: chunk.utf8)
        var events: [String] = []

        while let nlIdx = buffer.firstIndex(of: SSEParser.lf) {
            var raw = Array(buffer[..<nlIdx])
            buffer.removeSubrange(0...nlIdx)
            if raw.last == SSEParser.cr { raw.removeLast() }
            let line = String(decoding: raw, as: UTF8.self)

            if line.isEmpty {
                if !dataLines.isEmpty {
                    events.append(dataLines.joined(separator: "\n"))
                    dataLines.removeAll(keepingCapacity: true)
                }
                continue
            }

            if line.hasPrefix(":") {
                continue
            }

            if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                dataLines.append(String(value))
            }
            // Other SSE fields (event:, id:, retry:) are ignored — adapters
            // that need them can extend this.
        }

        return events
    }

    /// Flush any pending data block when the stream ends without a trailing
    /// blank line. Returns at most one event.
    mutating func finish() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let event = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        return event
    }
}
