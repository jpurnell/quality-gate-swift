import Foundation
import CorpusKit

/// Sends a system + user prompt to a cloud model and returns the text body.
/// Abstracted so the provider's orchestration is testable without a network.
public protocol NarrativeTransport: Sendable {
    /// Sends a system + user prompt to the model and returns the text body.
    func send(system: String, user: String, model: String, apiKey: String) async throws -> String
}

/// Errors surfaced by the Anthropic transport.
public enum AnthropicTransportError: LocalizedError {
    case invalidResponse
    case httpError(status: Int)
    case apiError(status: Int, message: String)
    case emptyResponse
    case missingKey

    /// A human-readable description of the transport failure.
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Anthropic API"
        case .httpError(let status): return "Anthropic API returned HTTP \(status)"
        case .apiError(let status, let message): return "Anthropic API error (\(status)): \(message)"
        case .emptyResponse: return "Anthropic API returned no text content"
        case .missingKey: return "No ANTHROPIC_API_KEY available"
        }
    }
}

/// The primary rung: cloud Claude over the whole-pulse prompt. Highest quality;
/// requires an API key and network. Available only when a non-empty key is set.
public struct AnthropicNarrativeProvider: NarrativeProvider {
    /// The source tag recorded for this provider (`claude`).
    public var source: NarrativeSource { .claude }

    private let apiKey: String?
    private let model: String
    private let promptBuilder: PortfolioPromptBuilder
    private let transport: any NarrativeTransport

    /// Creates the Claude provider. `transport` is injectable for testing.
    public init(
        apiKey: String?,
        model: String = "claude-sonnet-4-6",
        promptBuilder: PortfolioPromptBuilder = PortfolioPromptBuilder(),
        transport: any NarrativeTransport = URLSessionAnthropicTransport()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.promptBuilder = promptBuilder
        self.transport = transport
    }

    /// Available only when a non-empty API key is present.
    public func isAvailable(for input: NarrativeInput) -> Bool {
        guard let apiKey else { return false }
        return !apiKey.isEmpty
    }

    /// Builds the whole-pulse prompt and sends it to Claude via the transport.
    public func narrate(_ input: NarrativeInput) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw AnthropicTransportError.missingKey }
        let system = promptBuilder.systemPrompt()
        let user = promptBuilder.userPrompt(
            pulse: input.pulse,
            previousPulse: input.previousPulse,
            workLogsByProject: input.workLogsByProject
        )
        return try await transport.send(system: system, user: user, model: model, apiKey: apiKey)
    }
}

/// Live transport: POSTs to the Anthropic Messages API via URLSession.
public struct URLSessionAnthropicTransport: NarrativeTransport {
    private let maxTokens: Int
    private let timeout: TimeInterval

    /// Creates the live transport with a token cap and request timeout.
    public init(maxTokens: Int = 4096, timeout: TimeInterval = 120) {
        self.maxTokens = maxTokens
        self.timeout = timeout
    }

    /// POSTs the prompt to the Anthropic Messages API and returns the text body.
    public func send(system: String, user: String, model: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AnthropicTransportError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = timeout

        let body = Request(model: model, maxTokens: maxTokens, system: system, messages: [Message(role: "user", content: user)])
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnthropicTransportError.invalidResponse }
        guard http.statusCode == 200 else {
            if let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw AnthropicTransportError.apiError(status: http.statusCode, message: parsed.error.message)
            }
            throw AnthropicTransportError.httpError(status: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw AnthropicTransportError.emptyResponse
        }
        return text
    }

    private struct Request: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
    }
    private struct Message: Encodable { let role: String; let content: String }
    private struct Response: Decodable { let content: [Block] }
    private struct Block: Decodable { let type: String; let text: String? }
    private struct ErrorResponse: Decodable {
        let error: Detail
        struct Detail: Decodable { let message: String }
    }
}
