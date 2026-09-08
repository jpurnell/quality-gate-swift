import Foundation

/// Writes the `consistency:` block that registers a project with the corpus.
///
/// A pure transform over file contents so the cases that matter — idempotence, and never
/// emitting a block nothing reads — are testable without a filesystem. The caller owns
/// reading and writing.
public struct CorpusConfigWriter: Sendable {

    /// The outcome of considering a config file.
    public struct Result: Sendable, Equatable {
        /// Whether anything needs writing.
        public let changed: Bool
        /// The full new contents, or nil when the file should be left untouched.
        public let content: String?
    }

    /// Returns the contents `.quality-gate.yml` should have for this project to emit
    /// telemetry, or nothing when it already would.
    ///
    /// Only `consistency:` is written. `scripts/onboard-corpus.sh` also appended an `ijs:`
    /// block to every project it onboarded, and nothing decodes it — `Configuration`
    /// declares thirty sub-config blocks and `ijs` is not among them, so `Codable` drops
    /// the key without complaint. The result is inert configuration that reads as
    /// authoritative, which is how a corpus setting came to be duplicated across the
    /// portfolio in a form that has never had any effect.
    ///
    /// - Parameters:
    ///   - existing: current contents of `.quality-gate.yml`, or nil if there is no file.
    ///   - corpusPath: path to the corpus this project should write to.
    ///   - projectID: the identifier telemetry is written under.
    /// - Returns: `changed: false` and no content when a `consistency:` block is already
    ///   present — an existing block is the project's own decision and is never rewritten,
    ///   even when it points somewhere else.
    public static func ensureConsistencyBlock(
        in existing: String?,
        corpusPath: String,
        projectID: String
    ) -> Result {
        let block = """
            consistency:
              corpusPath: \(corpusPath)
              projectID: \(projectID)
              consistencyThreshold: 0.7
              defaultRiskTier: 2
            """

        guard let existing, !existing.isEmpty else {
            return Result(changed: true, content: block + "\n")
        }

        // A block already here is a decision someone made, including the choice of a
        // different corpus. Onboarding adds what is missing; it does not overwrite.
        //
        // Matched at the start of a line rather than anywhere in the file, so a mention
        // inside a comment or a nested key does not read as a declared block.
        // Split on any newline, not on "\n": a config written on Windows arrives as one
        // element, `hasBlock` reads false, and onboarding appends a second `consistency:`
        // block — the precise opposite of the guarantee above. Empty lines are irrelevant
        // here because the only question asked of each line is its prefix.
        let hasBlock = existing.split(whereSeparator: \.isNewline)
            .contains { $0.hasPrefix("consistency:") }
        if hasBlock {
            return Result(changed: false, content: nil)
        }

        // A file whose last line has no newline would otherwise have `consistency:` glued
        // onto it, producing YAML that parses as something else entirely.
        let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
        return Result(changed: true, content: existing + separator + block + "\n")
    }
}
