#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// The real on-device generator, backed by Apple's Foundation Models. Compiled
/// only where the framework is importable; gated to macOS/iOS 26+ at the type
/// level and to a runtime availability check via ``isAvailable``.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public struct SystemLanguageModelGenerator: OnDeviceNarrativeGenerator {
    private let temperature: Double

    /// Creates the generator with a fixed sampling temperature.
    public init(temperature: Double = 0.3) {
        self.temperature = temperature
    }

    /// Whether the on-device model is ready (Apple Intelligence enabled, downloaded).
    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Runs one instruction/prompt pair through a fresh `LanguageModelSession`.
    public func generate(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(temperature: temperature)
        )
        return response.content
    }
}
#endif
