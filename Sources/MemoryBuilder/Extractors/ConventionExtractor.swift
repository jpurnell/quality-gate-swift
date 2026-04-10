import Foundation

/// Extracts coding conventions from rules files and CLAUDE.md.
/// Skips rules already present in the global ~/.claude/CLAUDE.md.
public struct ConventionExtractor: MemoryExtractor, Sendable {
    public let id = "conventions"

    public init() {}

    public func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry] {
        // TODO: Implement — Phase 2
        []
    }
}
