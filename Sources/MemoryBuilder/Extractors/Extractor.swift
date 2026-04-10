import Foundation

/// Protocol for all memory extractors.
///
/// Each extractor reads a specific data source (Package.swift, git, ADRs, etc.)
/// and produces zero or more memory entries.
public protocol MemoryExtractor: Sendable {
    /// Unique identifier for this extractor.
    var id: String { get }

    /// Extract memory entries from the project at the given root path.
    /// - Parameters:
    ///   - projectRoot: Absolute path to the project root.
    ///   - guidelinesPath: Relative path to the development-guidelines directory.
    ///   - globalClaudeMD: Contents of ~/.claude/CLAUDE.md, if it exists. Used to avoid duplication.
    /// - Returns: Zero or more memory entries.
    func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry]
}
