import Foundation

/// Extracts active work from implementation checklists and git log.
public struct ActiveWorkExtractor: MemoryExtractor, Sendable {
    public let id = "activeWork"

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
