import Foundation

/// Extracts module architecture from Package.swift dependency graph.
public struct ArchitectureExtractor: MemoryExtractor, Sendable {
    public let id = "architecture"

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
