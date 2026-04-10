import Foundation

/// Extracts environment info (Swift version, platform).
public struct EnvironmentExtractor: MemoryExtractor, Sendable {
    public let id = "environment"

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
