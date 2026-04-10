import Foundation

/// Extracts ADR summary from the architecture decisions log.
public struct ADRExtractor: MemoryExtractor, Sendable {
    public let id = "adrSummary"

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
