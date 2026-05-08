import Foundation

/// Shared HTTP plumbing for JSON-over-HTTP LLM provider adapters.
///
/// This helper deliberately owns only transport concerns: request construction,
/// URLSession execution, and HTTP status-to-`LLMError.providerError` mapping.
/// Provider-specific request/response encoding stays inside each adapter.
struct HTTPTransport: Sendable {
    let providerName: String

    init(providerName: String) {
        self.providerName = providerName
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response: response, data: data, operation: "request")
        return data
    }

    func sendStreaming(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await checkStatusStreaming(response: response, bytes: bytes)
        return bytes
    }

    static func makeJSONRequest(
        url: URL,
        body: Data,
        headers: [String: String] = [:],
        stream: Bool = false,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = timeout
        request.httpBody = body
        return request
    }

    private func checkStatus(response: URLResponse, data: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("Non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.providerError(
                httpStatus: http.statusCode,
                message: "\(providerName) \(operation) failed",
                body: body
            )
        }
    }

    private func checkStatusStreaming(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("Non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            var collected = Data()
            for try await byte in bytes { collected.append(byte) }
            let body = String(data: collected, encoding: .utf8) ?? ""
            throw LLMError.providerError(
                httpStatus: http.statusCode,
                message: "\(providerName) stream failed",
                body: body
            )
        }
    }
}
