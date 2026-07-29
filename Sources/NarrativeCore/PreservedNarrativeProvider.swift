import Foundation
import CorpusKit

/// The penultimate rung: carry the previous pulse's narrative forward verbatim.
/// Available only when the prior pulse actually has a non-empty narrative — so a
/// transient outage never blanks the dashboard.
public struct PreservedNarrativeProvider: NarrativeProvider {
    /// The source tag recorded for this provider (`preservedLLM`).
    public var source: ProseSource { .preservedLLM }

    /// Creates the carry-forward provider.
    public init() {}

    /// Available only when the prior pulse has a non-empty narrative.
    public func isAvailable(for input: NarrativeInput) -> Bool {
        guard let prior = input.previousPulse?.narrative else { return false }
        return !prior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns the prior pulse's narrative verbatim.
    public func narrate(_ input: NarrativeInput) async throws -> String {
        guard let prior = input.previousPulse?.narrative,
              !prior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PreservedNarrativeError.noPriorNarrative
        }
        return prior
    }
}

/// Errors from the preserved-narrative rung.
public enum PreservedNarrativeError: LocalizedError {
    /// There was no prior narrative available to carry forward.
    case noPriorNarrative
    /// A human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case .noPriorNarrative: return "No prior narrative to carry forward"
        }
    }
}
