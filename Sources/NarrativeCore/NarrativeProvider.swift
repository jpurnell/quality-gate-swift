import Foundation
import CorpusKit

/// The structured input a narrative provider works from — the pulse plus the
/// context needed to explain it. Providers derive their own prompt shape from
/// this: the cloud provider builds one monolithic prompt; the on-device provider
/// shards it per project. The seam is deliberately above prompt construction,
/// because the two engines cannot share a prompt (69.5k tokens vs a 4,096-token
/// window).
public struct NarrativeInput: Sendable {
    /// The pulse to narrate.
    public let pulse: InstitutionalPulse
    /// The immediately preceding pulse, for deltas and carry-forward.
    public let previousPulse: InstitutionalPulse?
    /// Per-project work-logs (the causal record behind metric movements).
    public let workLogsByProject: [String: [WorkEvent]]

    /// Creates the structured input for a narrative provider.
    public init(
        pulse: InstitutionalPulse,
        previousPulse: InstitutionalPulse?,
        workLogsByProject: [String: [WorkEvent]]
    ) {
        self.pulse = pulse
        self.previousPulse = previousPulse
        self.workLogsByProject = workLogsByProject
    }
}

/// One rung of the narrative durability chain. A provider reports whether it can
/// run for a given input, and, if so, produces the narrative markdown body.
public protocol NarrativeProvider: Sendable {
    /// The source tag recorded when this provider produces the narrative.
    var source: ProseSource { get }

    /// Whether this provider can run right now for `input` — e.g. an API key is
    /// present, the on-device model is available, or a prior narrative exists.
    /// Cheap and non-throwing; the chain uses it to skip unavailable rungs.
    func isAvailable(for input: NarrativeInput) -> Bool

    /// Produces the narrative markdown body. Throwing (or returning empty)
    /// demotes to the next rung.
    func narrate(_ input: NarrativeInput) async throws -> String
}
