import Foundation
import CorpusKit
#if canImport(os)
import os
#endif

/// The narrative produced by the chain, tagged with the rung that spoke.
public struct NarrativeResult: Sendable, Equatable {
    /// The generated narrative markdown body.
    public let text: String
    /// Which rung of the chain produced it.
    public let source: ProseSource

    /// Creates a tagged narrative result.
    public init(text: String, source: ProseSource) {
        self.text = text
        self.source = source
    }
}

/// The durability chain: tries providers in priority order and returns the first
/// non-empty success, recording which rung produced it. An unavailable provider
/// is skipped; a throwing or empty-producing provider demotes to the next rung.
/// Returns `nil` only when no provider could produce a narrative.
public struct NarrativeChain: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.quality-gate", category: "NarrativeChain")
    #endif

    /// Providers in descending priority (primary first).
    public let providers: [any NarrativeProvider]

    /// Creates a chain from providers in descending priority (primary first).
    public init(providers: [any NarrativeProvider]) {
        self.providers = providers
    }

    /// Runs the chain, returning the first rung's non-empty narrative.
    public func narrate(_ input: NarrativeInput) async -> NarrativeResult? {
        for provider in providers {
            guard provider.isAvailable(for: input) else { continue }
            do {
                let text = try await provider.narrate(input)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    #if canImport(os)
                    Self.logger.notice("Provider \(provider.source.rawValue, privacy: .public) returned empty; demoting to next rung")
                    #endif
                    continue
                }
                return NarrativeResult(text: text, source: provider.source)
            } catch {
                #if canImport(os)
                Self.logger.notice("Provider \(provider.source.rawValue, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); demoting to next rung")
                #endif
                continue
            }
        }
        return nil
    }
}
