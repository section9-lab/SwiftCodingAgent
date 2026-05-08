import Foundation

/// Small helpers for safely shaping `[String: Any]` payloads built with
/// `JSONSerialization`. Kept internal to the SDK; clients should not depend
/// on this surface.
enum JSONHelpers {
    /// Decode `text` as a JSON object. Returns an empty object on failure so
    /// encoders never crash on a model returning malformed arguments — the
    /// downstream tool runner will surface the parse error.
    static func parseObject(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Decode `text` into any JSON value (object, array, string, number, bool, null).
    static func parseAny(_ text: String) -> Any {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return [:] }
        return obj
    }

    /// Serialise `value` back to a JSON string. Returns `"{}"` on failure.
    static func serialize(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }
}
