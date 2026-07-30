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

    /// Runs one instruction/prompt pair through a fresh `LanguageModelSession`
    /// using guided generation.
    ///
    /// Constrained sampling against the ``GuidedNarrative`` schema keeps the
    /// model's output inside a single markdown `body` field, structurally
    /// preventing the hallucinated tool-call preamble the small model
    /// occasionally emitted on the raw-string path (the caller's `sanitize`
    /// pass remains a belt-and-suspenders backstop).
    public func generate(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: GuidedNarrative.self,
            options: GenerationOptions(temperature: temperature)
        )
        return response.content.body
    }
}

/// The guided-generation schema for a narrative: one markdown body, no
/// scaffolding. Constrained sampling fills exactly this shape, structurally
/// preventing hallucinated tool-call preamble.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@Generable(description: "A quality-gate narrative in markdown.")
private struct GuidedNarrative {
    @Guide(description: "The narrative in markdown. No preamble, no tool-call syntax, no emoji.")
    var body: String
}
#endif
