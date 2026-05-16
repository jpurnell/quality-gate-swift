import Foundation
import IJSSensor
import os

/// Reads quality gate telemetry from a corpus directory.
///
/// Expected layout:
/// ```
/// <corpusPath>/telemetry/<project>/<date>/<timestamp>_metadata.json
/// ```
public struct CorpusReader: Sendable {
    private let corpusPath: String
    private static let logger = Logger(subsystem: "com.quality-gate", category: "CorpusReader")

    /// Creates a reader for the given corpus directory.
    public init(corpusPath: String) {
        self.corpusPath = corpusPath
    }

    /// Discovers all project IDs in the corpus.
    public func discoverProjects() throws -> [String] {
        let telemetryPath = "\(corpusPath)/telemetry" // SAFETY: corpusPath is set by configuration, not user input
        let fm = FileManager.default
        guard fm.fileExists(atPath: telemetryPath) else { return [] } // SAFETY: read-only existence check on configured path
        let contents = try fm.contentsOfDirectory(atPath: telemetryPath) // SAFETY: reads configured corpus directory
        return contents.filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: "\(telemetryPath)/\(name)", isDirectory: &isDir) && isDir.boolValue // SAFETY: reads subdir of configured corpus
        }
    }

    /// Loads all runs for a project, sorted by timestamp.
    public func loadRuns(for project: String) throws -> [TimestampedRun] {
        let projectPath = "\(corpusPath)/telemetry/\(project)" // SAFETY: corpusPath from configuration; project from discoverProjects
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectPath) else { return [] } // SAFETY: read-only existence check

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var runs: [TimestampedRun] = []
        let dateDirs = try fm.contentsOfDirectory(atPath: projectPath) // SAFETY: reads configured corpus subdirectory
        for dateDir in dateDirs {
            let datePath = "\(projectPath)/\(dateDir)" // SAFETY: child of configured corpus path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: datePath, isDirectory: &isDir), isDir.boolValue else { continue } // SAFETY: read-only directory check

            let files = try fm.contentsOfDirectory(atPath: datePath) // SAFETY: reads date subdirectory of corpus
            for file in files where file.hasSuffix("_metadata.json") {
                let filePath = "\(datePath)/\(file)" // SAFETY: child of configured corpus path
                guard let data = fm.contents(atPath: filePath) else { continue } // SAFETY: reads JSON from corpus
                do {
                    let metadata = try decoder.decode(CheckResultMetadata.self, from: data)
                    runs.append(TimestampedRun(metadata: metadata))
                } catch {
                    Self.logger.warning("Skipping malformed JSON at \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
        }

        return runs.sorted { $0.metadata.timestamp < $1.metadata.timestamp }
    }

    /// Loads all projects and their runs.
    public func loadAll() throws -> [String: [TimestampedRun]] {
        let projects = try discoverProjects()
        var result: [String: [TimestampedRun]] = [:]
        for project in projects {
            result[project] = try loadRuns(for: project)
        }
        return result
    }
}
