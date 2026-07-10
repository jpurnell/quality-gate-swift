import Foundation
import CorpusKit

/// Detects a provider-verified run identity from the process environment
/// (Phase 2, CI parity).
///
/// Only a CI provider's own attestation builds a ``CIIdentity`` — a bare
/// `CI=true` or a partial set of variables stays an asserted identity
/// (`nil` here), because a half-verified identity is worse than an honest
/// asserted one.
public enum CIIdentityProbe {
    /// The verified identity for this run, or nil for local/unknown
    /// environments.
    ///
    /// - Parameter environment: Process environment (injectable for tests).
    public static func detect(environment: [String: String]) -> CIIdentity? {
        guard environment["GITHUB_ACTIONS"] == "true",
              let actor = environment["GITHUB_ACTOR"],
              let workflowRunID = environment["GITHUB_RUN_ID"],
              let commit = environment["GITHUB_SHA"],
              let repository = environment["GITHUB_REPOSITORY"] else {
            return nil
        }
        return CIIdentity(
            provider: "github-actions",
            actor: actor,
            workflowRunID: workflowRunID,
            commit: commit,
            repository: repository)
    }
}
