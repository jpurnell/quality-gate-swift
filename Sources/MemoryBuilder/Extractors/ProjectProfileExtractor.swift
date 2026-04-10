import Foundation

/// Extracts project profile from Package.swift and README.
public struct ProjectProfileExtractor: MemoryExtractor, Sendable {
    public let id = "projectProfile"

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
